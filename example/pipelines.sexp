; Named step sequences. Every app gets rollout and rollout-edge; an app needs
; an entry under (apps ...) only for something extra.
(
  (default (
    (rollout      (sequence (prefer deploy bootstrap) check))
    (rollout-edge (sequence (prefer deploy bootstrap) edge check))
  ))
  (apps (
    ; The receiver, then the host relay and jail senders, then the edge's
    ; private routes before the guest and edge senders probe them.
    (logs (
      (rollout-edge
        (sequence bootstrap compute-logging edge (guest-logging ledger) edge-logging vmui-auth check
                  (script check-forwarding $COMPUTE_TARGET)))
      (forwarding (sequence compute-logging (script check-forwarding $COMPUTE_TARGET)))
      (replace-forwarding (sequence compute-logging-replace (script check-forwarding $COMPUTE_TARGET)))
      ; No bootstrap or edge: inspect all three installed units before
      ; repairing any of them, then verify the receiver.
      (recover
        (sequence (recover-guest-check ledger) recover-edge-check recover-auth-check
                  (recover-guest ledger) recover-edge recover-auth check
                  (recover-guest-health ledger) recover-edge-health recover-auth-health))
    ))
  ))
)
