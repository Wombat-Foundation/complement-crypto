package tests

import (
	"github.com/matrix-org/gomatrixserverlib/spec"
	"strings"
	"testing"
	"time"

	"github.com/matrix-org/complement-crypto/internal/api"
	"github.com/matrix-org/complement-crypto/internal/deploy/callback"
	"github.com/matrix-org/complement-crypto/internal/deploy/mitm"
	"github.com/matrix-org/complement/ct"
	"github.com/matrix-org/complement/helpers"
	"github.com/matrix-org/complement/must"
)

// Test that clients wait for invites to be processed before sending encrypted messages.
// Consider:
//   - Alice is in a E2EE room and invites Bob, the request has yet to 200 OK.
//   - Alice tries to send a message in the room. This should be queued behind the invite.
//     If it is not, the message will not be encrypted for Bob.
//
// It is valid for SDKs to simply document that you shouldn't call Invite and SendMessage concurrently.
// Therefore, we will not test this.
//
// However, consider:
//   - Alice is in a E2EE room and invites Bob. The request 200 OKs but has yet to come down /sync.
//   - Alice tries to send a message in the room.
//   - Alice should encrypt for Bob.
//
// This is much more realistic, as servers are typically asynchronous internally so /invite can 200 OK
// _before_ it comes down /sync.
func TestDelayedInviteResponse(t *testing.T) {
	Instance().ForEachClientType(t, func(t *testing.T, clientType api.ClientType) {
		tc := Instance().CreateTestContext(t, clientType, clientType)
		roomID := tc.CreateNewEncryptedRoom(t, tc.Alice)
		tc.WithAliceAndBobSyncing(t, func(alice, bob api.TestClient) {
			// we send a message first so clients which lazily call /members can do so now.
			// if we don't do this, the client won't rely on /sync for the member list so won't fail.
			alice.MustSendMessage(t, roomID, "dummy message to make /members call")

			config := tc.Deployment.MITM().Configure(t)
			serverHasInvite := helpers.NewWaiter()
			const delayTime = 3 * time.Second
			config.WithIntercept(mitm.InterceptOpts{
				Filter: mitm.FilterParams{
					PathContains: "/sync",
					AccessToken:  alice.CurrentAccessToken(t),
				},
				ResponseCallback: func(cd callback.Data) *callback.Response {
					if strings.Contains(
						strings.ReplaceAll(string(cd.ResponseBody), " ", ""),
						`"membership":"invite"`,
					) {
						t.Logf("/sync => %v", string(cd.ResponseBody))
						t.Logf("intercepted /sync response which has the invite, tarpitting for %v - %v", delayTime, cd)
						serverHasInvite.Finish()
						time.Sleep(delayTime)
					}
					return nil
				},
			}, func() {
				t.Logf("Alice about to /invite Bob")
				if err := alice.InviteUser(t, roomID, bob.UserID()); err != nil {
					ct.Errorf(t, "failed to invite user: %s", err)
				}
				t.Logf("Alice /invited Bob")
				// once the server got the invite, send a message
				serverHasInvite.Waitf(t, 3*time.Second, "did not intercept invite")
				t.Logf("intercepted invite; sending message")
				eventID := alice.MustSendMessage(t, roomID, "hello world!")

				// bob joins, ensure he can decrypt the message.
				tc.Bob.JoinRoom(t, roomID, []spec.ServerName{clientType.HS})
				bob.WaitUntilEventInRoom(t, roomID, api.CheckEventHasMembership(tc.Bob.UserID, "join")).Waitf(t, 7*time.Second, "did not see own join")
				bob.MustBackpaginate(t, roomID, 3)

				// poll until the event is either decrypted or known-undecryptable
				var ev *api.Event
				deadline := time.Now().Add(10 * time.Second)
				for {
					var err error
					if err = bob.Backpaginate(t, roomID, 3); err == nil {
						if ev, err = bob.GetEvent(t, roomID, eventID); err == nil && (ev.FailedToDecrypt || ev.Text != "") {
							break
						}
					}
					if time.Now().After(deadline) {
						t.Fatalf("event %s never settled in bob's timeline (last err: %v)", eventID, err)
					}
					time.Sleep(250 * time.Millisecond)
				}

				// Both langs run the real race: Alice sends while the invite /sync is still
				// tarpitted. rust-sdk#3622 no longer reproduces; js needs the fix for
				// matrix-js-sdk#4291 (refresh crypto membership after a successful /invite).
				must.Equal(t, ev.FailedToDecrypt, false, "failed to decrypt event")
				must.Equal(t, ev.Text, "hello world!", "failed to decrypt plaintext")
			})
		})
	})
}
