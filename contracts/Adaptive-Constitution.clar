;; Adaptive Constitution Contract - A DAO whose rules rewrite themselves based on outcomes

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_PROPOSAL_NOT_FOUND (err u101))
(define-constant ERR_ALREADY_VOTED (err u102))
(define-constant ERR_VOTING_CLOSED (err u103))
(define-constant ERR_INSUFFICIENT_POWER (err u104))
(define-constant ERR_INVALID_INPUT (err u105))

;; Data Variables
(define-data-var proposal-counter uint u0)
(define-data-var min-voting-power uint u1)
(define-data-var voting-period uint u1440) ;; blocks (~10 days)
(define-data-var quorum-threshold uint u50) ;; percentage
(define-data-var success-threshold uint u60) ;; percentage for passing

;; Constitution Rules Storage
(define-map constitution-rules
  { rule-id: uint }
  { 
    rule-text: (string-ascii 500),
    weight: uint,
    active: bool,
    created-at: uint
  }
)

;; Proposals
(define-map proposals
  { proposal-id: uint }
  {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    rule-changes: (list 5 {rule-id: uint, new-text: (string-ascii 500), new-weight: uint}),
    yes-votes: uint,
    no-votes: uint,
    start-block: uint,
    end-block: uint,
    executed: bool
  }
)

;; Voting Records
(define-map votes
  { proposal-id: uint, voter: principal }
  { vote: bool, power: uint }
)

;; Member Voting Power
(define-map voting-power
  { member: principal }
  { power: uint, last-updated: uint }
)

;; Proposal Outcomes History
(define-map proposal-outcomes
  { proposal-id: uint }
  { 
    passed: bool,
    effectiveness-score: uint,
    measured-at: uint
  }
)

;; Initialize Constitution with Basic Rules
(define-private (initialize-constitution)
  (begin
    (map-set constitution-rules 
      { rule-id: u1 }
      { rule-text: "Proposals require 60% approval to pass", weight: u100, active: true, created-at: block-height })
    (map-set constitution-rules 
      { rule-id: u2 }
      { rule-text: "Voting period lasts 1440 blocks", weight: u100, active: true, created-at: block-height })
    (map-set constitution-rules 
      { rule-id: u3 }
      { rule-text: "Minimum quorum is 50% of voting power", weight: u100, active: true, created-at: block-height })
    (ok true)
  )
)

;; Create New Proposal
(define-public (create-proposal 
    (title (string-ascii 100))
    (description (string-ascii 500))
    (rule-changes (list 5 {rule-id: uint, new-text: (string-ascii 500), new-weight: uint})))
  (let 
    (
      (proposal-id (+ (var-get proposal-counter) u1))
      (voter-power (default-to u0 (get power (map-get? voting-power { member: tx-sender }))))
    )
    (asserts! (> (len title) u0) ERR_INVALID_INPUT)
    (asserts! (> (len description) u0) ERR_INVALID_INPUT)
    (asserts! (> (len rule-changes) u0) ERR_INVALID_INPUT)
    (asserts! (>= voter-power (var-get min-voting-power)) ERR_INSUFFICIENT_POWER)
    (map-set proposals
      { proposal-id: proposal-id }
      {
        proposer: tx-sender,
        title: title,
        description: description,
        rule-changes: rule-changes,
        yes-votes: u0,
        no-votes: u0,
        start-block: block-height,
        end-block: (+ block-height (var-get voting-period)),
        executed: false
      }
    )
    (var-set proposal-counter proposal-id)
    (ok proposal-id)
  )
)

;; Cast Vote
(define-public (vote (proposal-id uint) (support bool))
  (let 
    (
      (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR_PROPOSAL_NOT_FOUND))
      (voter-power (default-to u1 (get power (map-get? voting-power { member: tx-sender }))))
      (existing-vote (map-get? votes { proposal-id: proposal-id, voter: tx-sender }))
    )
    (asserts! (> proposal-id u0) ERR_INVALID_INPUT)
    (asserts! (is-none existing-vote) ERR_ALREADY_VOTED)
    (asserts! (<= block-height (get end-block proposal)) ERR_VOTING_CLOSED)

    (map-set votes
      { proposal-id: proposal-id, voter: tx-sender }
      { vote: support, power: voter-power }
    )

    (if support
      (map-set proposals
        { proposal-id: proposal-id }
        (merge proposal { yes-votes: (+ (get yes-votes proposal) voter-power) })
      )
      (map-set proposals
        { proposal-id: proposal-id }
        (merge proposal { no-votes: (+ (get no-votes proposal) voter-power) })
      )
    )
    (ok true)
  )
)

;; Execute Proposal
(define-public (execute-proposal (proposal-id uint))
  (let 
    (
      (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR_PROPOSAL_NOT_FOUND))
      (total-votes (+ (get yes-votes proposal) (get no-votes proposal)))
      (total-power (fold + (map get-member-power (get-all-members)) u0))
      (quorum-met (>= (* total-votes u100) (* total-power (var-get quorum-threshold))))
      (proposal-passed (and quorum-met 
                           (>= (* (get yes-votes proposal) u100) 
                               (* total-votes (var-get success-threshold)))))
    )
    (asserts! (> proposal-id u0) ERR_INVALID_INPUT)
    (asserts! (> block-height (get end-block proposal)) ERR_VOTING_CLOSED)
    (asserts! (not (get executed proposal)) ERR_UNAUTHORIZED)

    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal { executed: true })
    )

    (if proposal-passed
      (begin
        (unwrap-panic (apply-rule-changes proposal-id (get rule-changes proposal)))
        (map-set proposal-outcomes
          { proposal-id: proposal-id }
          { passed: true, effectiveness-score: u0, measured-at: block-height }
        )
      )
      (map-set proposal-outcomes
        { proposal-id: proposal-id }
        { passed: false, effectiveness-score: u0, measured-at: block-height }
      )
    )
    (ok proposal-passed)
  )
)

;; Apply Rule Changes from Successful Proposal
(define-private (apply-rule-changes 
    (proposal-id uint) 
    (changes (list 5 {rule-id: uint, new-text: (string-ascii 500), new-weight: uint})))
  (ok (map apply-single-rule-change changes))
)

(define-private (apply-single-rule-change (change {rule-id: uint, new-text: (string-ascii 500), new-weight: uint}))
  (let 
    (
      (rule-id (get rule-id change))
      (existing-rule (map-get? constitution-rules { rule-id: rule-id }))
    )
    (map-set constitution-rules
      { rule-id: rule-id }
      {
        rule-text: (get new-text change),
        weight: (get new-weight change),
        active: true,
        created-at: block-height
      }
    )
    true
  )
)

;; Adaptive Mechanism: Update Rules Based on Outcomes
(define-public (measure-proposal-effectiveness (proposal-id uint) (effectiveness-score uint))
  (let 
    (
      (outcome (unwrap! (map-get? proposal-outcomes { proposal-id: proposal-id }) ERR_PROPOSAL_NOT_FOUND))
    )
    (asserts! (> proposal-id u0) ERR_INVALID_INPUT)
    (asserts! (<= effectiveness-score u100) ERR_INVALID_INPUT)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)

    (map-set proposal-outcomes
      { proposal-id: proposal-id }
      (merge outcome { effectiveness-score: effectiveness-score, measured-at: block-height })
    )

    ;; Adaptive logic: adjust thresholds based on effectiveness
    (if (and (get passed outcome) (< effectiveness-score u30))
      ;; If passed proposals are ineffective, increase threshold
      (let ((new-threshold (+ (var-get success-threshold) u5)))
        (begin
          (var-set success-threshold (if (> new-threshold u80) u80 new-threshold))
          true))
      ;; If proposals are effective or failed ones would have been better, decrease threshold
      (if (> effectiveness-score u70)
        (let ((new-threshold (- (var-get success-threshold) u2)))
          (begin
            (var-set success-threshold (if (< new-threshold u51) u51 new-threshold))
            true))
        false
      )
    )
    (ok true)
  )
)

;; Grant Voting Power
(define-public (grant-voting-power (member principal) (power uint))
  (begin
    (asserts! (not (is-eq member tx-sender)) ERR_INVALID_INPUT)
    (asserts! (> power u0) ERR_INVALID_INPUT)
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set voting-power
      { member: member }
      { power: power, last-updated: block-height }
    )
    (ok true)
  )
)

;; Read-only functions
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

(define-read-only (get-constitution-rule (rule-id uint))
  (map-get? constitution-rules { rule-id: rule-id })
)

(define-read-only (get-voting-power (member principal))
  (default-to u0 (get power (map-get? voting-power { member: member })))
)

(define-read-only (get-proposal-outcome (proposal-id uint))
  (map-get? proposal-outcomes { proposal-id: proposal-id })
)

(define-read-only (get-current-thresholds)
  {
    success-threshold: (var-get success-threshold),
    quorum-threshold: (var-get quorum-threshold),
    voting-period: (var-get voting-period)
  }
)

;; Helper functions
(define-private (get-member-power (member principal))
  (default-to u0 (get power (map-get? voting-power { member: member })))
)

(define-private (get-all-members)
  ;; Simplified - in practice would need to track all members
  (list tx-sender)
)

;; Initialize the contract
(initialize-constitution)