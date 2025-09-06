;; Reward Distributor Contract
;; A comprehensive staking and reward distribution system for yield farming optimization

;; ===== CONSTANTS =====

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-INSUFFICIENT-BALANCE (err u102))
(define-constant ERR-POOL-NOT-FOUND (err u103))
(define-constant ERR-ALREADY-STAKED (err u104))
(define-constant ERR-NOT-STAKED (err u105))
(define-constant ERR-REWARD-POOL-EMPTY (err u106))
(define-constant ERR-INVALID-POOL-ID (err u107))
(define-constant ERR-POOL-PAUSED (err u108))

;; Contract settings
(define-constant CONTRACT-OWNER tx-sender)
(define-constant REWARD-MULTIPLIER u1000)  ;; 1000 = 1.0 (base rate)
(define-constant MIN-STAKE-AMOUNT u1000000) ;; Minimum 1 STX to stake
(define-constant BLOCKS-PER-DAY u144) ;; Approximate blocks per day
(define-constant MAX-REWARD-POOLS u10)

;; ===== DATA VARIABLES =====

;; Global contract state
(define-data-var total-staked uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var next-pool-id uint u1)
(define-data-var contract-paused bool false)

;; ===== DATA MAPS =====

;; User staking information
(define-map user-stakes
  { user: principal, pool-id: uint }
  {
    amount: uint,
    start-block: uint,
    last-claim-block: uint,
    accumulated-rewards: uint
  }
)

;; Reward pool configurations
(define-map reward-pools
  { pool-id: uint }
  {
    name: (string-utf8 50),
    reward-rate: uint,  ;; Rewards per block per STX staked (scaled by REWARD-MULTIPLIER)
    total-staked: uint,
    reward-balance: uint,
    is-active: bool,
    min-lock-period: uint  ;; Minimum blocks to lock stake
  }
)

;; User balances and total stakes
(define-map user-total-stakes
  { user: principal }
  { total-amount: uint, pools-count: uint }
)

;; Pool statistics for analytics
(define-map pool-stats
  { pool-id: uint }
  {
    total-users: uint,
    total-rewards-paid: uint,
    creation-block: uint
  }
)

;; ===== PRIVATE FUNCTIONS =====

;; Calculate pending rewards for a user in a specific pool
(define-private (calculate-pending-rewards (user principal) (pool-id uint))
  (let (
    (stake-info (unwrap! (map-get? user-stakes { user: user, pool-id: pool-id }) u0))
    (pool-info (unwrap! (map-get? reward-pools { pool-id: pool-id }) u0))
    (blocks-elapsed (- block-height (get last-claim-block stake-info)))
    (reward-rate (get reward-rate pool-info))
    (staked-amount (get amount stake-info))
  )
    (/ (* staked-amount reward-rate blocks-elapsed) REWARD-MULTIPLIER)
  )
)

;; Update user's accumulated rewards
(define-private (update-user-rewards (user principal) (pool-id uint))
  (let (
    (current-stake (unwrap! (map-get? user-stakes { user: user, pool-id: pool-id }) false))
    (pending-rewards (calculate-pending-rewards user pool-id))
    (updated-rewards (+ (get accumulated-rewards current-stake) pending-rewards))
  )
    (map-set user-stakes
      { user: user, pool-id: pool-id }
      (merge current-stake {
        accumulated-rewards: updated-rewards,
        last-claim-block: block-height
      })
    )
    true
  )
)

;; Validate pool exists and is active
(define-private (is-valid-active-pool (pool-id uint))
  (match (map-get? reward-pools { pool-id: pool-id })
    pool-info (get is-active pool-info)
    false
  )
)

;; Check if minimum lock period has passed
(define-private (can-unstake (user principal) (pool-id uint))
  (let (
    (stake-info (unwrap! (map-get? user-stakes { user: user, pool-id: pool-id }) false))
    (pool-info (unwrap! (map-get? reward-pools { pool-id: pool-id }) false))
    (blocks-staked (- block-height (get start-block stake-info)))
    (min-lock-period (get min-lock-period pool-info))
  )
    (>= blocks-staked min-lock-period)
  )
)

;; ===== ADMIN FUNCTIONS =====

;; Create a new reward pool (admin only)
(define-public (create-reward-pool (name (string-utf8 50)) (reward-rate uint) (min-lock-period uint))
  (let (
    (pool-id (var-get next-pool-id))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (< pool-id MAX-REWARD-POOLS) ERR-INVALID-POOL-ID)
    (asserts! (> reward-rate u0) ERR-INVALID-AMOUNT)
    
    ;; Create the pool
    (map-set reward-pools
      { pool-id: pool-id }
      {
        name: name,
        reward-rate: reward-rate,
        total-staked: u0,
        reward-balance: u0,
        is-active: true,
        min-lock-period: min-lock-period
      }
    )
    
    ;; Initialize pool stats
    (map-set pool-stats
      { pool-id: pool-id }
      {
        total-users: u0,
        total-rewards-paid: u0,
        creation-block: block-height
      }
    )
    
    ;; Increment pool counter
    (var-set next-pool-id (+ pool-id u1))
    
    (ok pool-id)
  )
)

;; Fund a reward pool (admin only)
(define-public (fund-reward-pool (pool-id uint) (amount uint))
  (let (
    (pool-info (unwrap! (map-get? reward-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Update pool reward balance
    (map-set reward-pools
      { pool-id: pool-id }
      (merge pool-info {
        reward-balance: (+ (get reward-balance pool-info) amount)
      })
    )
    
    (ok true)
  )
)

;; Toggle pool active state (admin only)
(define-public (toggle-pool-state (pool-id uint))
  (let (
    (pool-info (unwrap! (map-get? reward-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    
    (map-set reward-pools
      { pool-id: pool-id }
      (merge pool-info {
        is-active: (not (get is-active pool-info))
      })
    )
    
    (ok (not (get is-active pool-info)))
  )
)

;; Pause/unpause contract (admin only)
(define-public (toggle-contract-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set contract-paused (not (var-get contract-paused)))
    (ok (var-get contract-paused))
  )
)

;; ===== PUBLIC STAKING FUNCTIONS =====

;; Stake STX in a specific pool
(define-public (stake-tokens (pool-id uint) (amount uint))
  (let (
    (pool-info (unwrap! (map-get? reward-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
    (current-stake (map-get? user-stakes { user: tx-sender, pool-id: pool-id }))
    (user-totals (default-to { total-amount: u0, pools-count: u0 } 
                             (map-get? user-total-stakes { user: tx-sender })))
  )
    ;; Validations
    (asserts! (not (var-get contract-paused)) ERR-POOL-PAUSED)
    (asserts! (get is-active pool-info) ERR-POOL-PAUSED)
    (asserts! (>= amount MIN-STAKE-AMOUNT) ERR-INVALID-AMOUNT)
    (asserts! (is-none current-stake) ERR-ALREADY-STAKED)
    
    ;; Create new stake record
    (map-set user-stakes
      { user: tx-sender, pool-id: pool-id }
      {
        amount: amount,
        start-block: block-height,
        last-claim-block: block-height,
        accumulated-rewards: u0
      }
    )
    
    ;; Update pool totals
    (map-set reward-pools
      { pool-id: pool-id }
      (merge pool-info {
        total-staked: (+ (get total-staked pool-info) amount)
      })
    )
    
    ;; Update user totals
    (map-set user-total-stakes
      { user: tx-sender }
      {
        total-amount: (+ (get total-amount user-totals) amount),
        pools-count: (+ (get pools-count user-totals) u1)
      }
    )
    
    ;; Update global and pool stats
    (var-set total-staked (+ (var-get total-staked) amount))
    
    (let (
      (current-stats (unwrap! (map-get? pool-stats { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
    )
      (map-set pool-stats
        { pool-id: pool-id }
        (merge current-stats {
          total-users: (+ (get total-users current-stats) u1)
        })
      )
    )
    
    (ok true)
  )
)

;; Claim accumulated rewards from a specific pool
(define-public (claim-rewards (pool-id uint))
  (let (
    (stake-info (unwrap! (map-get? user-stakes { user: tx-sender, pool-id: pool-id }) ERR-NOT-STAKED))
    (pool-info (unwrap! (map-get? reward-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
  )
    (asserts! (not (var-get contract-paused)) ERR-POOL-PAUSED)
    (asserts! (get is-active pool-info) ERR-POOL-PAUSED)
    
    ;; Update rewards before claiming
    (update-user-rewards tx-sender pool-id)
    
    (let (
      (updated-stake (unwrap! (map-get? user-stakes { user: tx-sender, pool-id: pool-id }) ERR-NOT-STAKED))
      (rewards-to-claim (get accumulated-rewards updated-stake))
    )
      (asserts! (> rewards-to-claim u0) ERR-INVALID-AMOUNT)
      (asserts! (>= (get reward-balance pool-info) rewards-to-claim) ERR-REWARD-POOL-EMPTY)
      
      ;; Reset accumulated rewards
      (map-set user-stakes
        { user: tx-sender, pool-id: pool-id }
        (merge updated-stake { accumulated-rewards: u0 })
      )
      
      ;; Update pool reward balance
      (map-set reward-pools
        { pool-id: pool-id }
        (merge pool-info {
          reward-balance: (- (get reward-balance pool-info) rewards-to-claim)
        })
      )
      
      ;; Update global statistics
      (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) rewards-to-claim))
      
      ;; Update pool statistics
      (let (
        (current-stats (unwrap! (map-get? pool-stats { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
      )
        (map-set pool-stats
          { pool-id: pool-id }
          (merge current-stats {
            total-rewards-paid: (+ (get total-rewards-paid current-stats) rewards-to-claim)
          })
        )
      )
      
      (ok rewards-to-claim)
    )
  )
)

;; Unstake tokens from a specific pool
(define-public (unstake-tokens (pool-id uint))
  (let (
    (stake-info (unwrap! (map-get? user-stakes { user: tx-sender, pool-id: pool-id }) ERR-NOT-STAKED))
    (pool-info (unwrap! (map-get? reward-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
    (user-totals (unwrap! (map-get? user-total-stakes { user: tx-sender }) ERR-NOT-STAKED))
    (staked-amount (get amount stake-info))
  )
    (asserts! (not (var-get contract-paused)) ERR-POOL-PAUSED)
    (asserts! (can-unstake tx-sender pool-id) ERR-UNAUTHORIZED)
    
    ;; Claim any pending rewards first
    (update-user-rewards tx-sender pool-id)
    
    ;; Remove stake record
    (map-delete user-stakes { user: tx-sender, pool-id: pool-id })
    
    ;; Update pool totals
    (map-set reward-pools
      { pool-id: pool-id }
      (merge pool-info {
        total-staked: (- (get total-staked pool-info) staked-amount)
      })
    )
    
    ;; Update user totals
    (map-set user-total-stakes
      { user: tx-sender }
      {
        total-amount: (- (get total-amount user-totals) staked-amount),
        pools-count: (- (get pools-count user-totals) u1)
      }
    )
    
    ;; Update global stats
    (var-set total-staked (- (var-get total-staked) staked-amount))
    
    (ok staked-amount)
  )
)

;; ===== READ-ONLY FUNCTIONS =====

;; Get user stake information for a specific pool
(define-read-only (get-user-stake (user principal) (pool-id uint))
  (map-get? user-stakes { user: user, pool-id: pool-id })
)

;; Get pool information
(define-read-only (get-pool-info (pool-id uint))
  (map-get? reward-pools { pool-id: pool-id })
)

;; Get pool statistics
(define-read-only (get-pool-stats (pool-id uint))
  (map-get? pool-stats { pool-id: pool-id })
)

;; Get user's pending rewards for a specific pool
(define-read-only (get-pending-rewards (user principal) (pool-id uint))
  (match (map-get? user-stakes { user: user, pool-id: pool-id })
    stake-info (ok (+ (get accumulated-rewards stake-info) (calculate-pending-rewards user pool-id)))
    ERR-NOT-STAKED
  )
)

;; Get user total stakes across all pools
(define-read-only (get-user-totals (user principal))
  (map-get? user-total-stakes { user: user })
)

;; Get global contract statistics
(define-read-only (get-global-stats)
  {
    total-staked: (var-get total-staked),
    total-rewards-distributed: (var-get total-rewards-distributed),
    total-pools: (- (var-get next-pool-id) u1),
    contract-paused: (var-get contract-paused)
  }
)
