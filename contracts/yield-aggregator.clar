;; Yield Aggregator Contract
;; A comprehensive yield farming aggregation system for optimal returns

;; ===== CONSTANTS =====

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-INVALID-AMOUNT (err u201))
(define-constant ERR-INSUFFICIENT-BALANCE (err u202))
(define-constant ERR-POOL-NOT-FOUND (err u203))
(define-constant ERR-POOL-FULL (err u204))
(define-constant ERR-POOL-CLOSED (err u205))
(define-constant ERR-INVALID-STRATEGY (err u206))
(define-constant ERR-SLIPPAGE-TOO-HIGH (err u207))
(define-constant ERR-COOLDOWN-ACTIVE (err u208))
(define-constant ERR-INVALID-FEE (err u209))
(define-constant ERR-REBALANCE-NOT-NEEDED (err u210))

;; Contract settings
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MAX-POOLS u20)
(define-constant BASE-FEE-RATE u100) ;; 1% = 100 basis points
(define-constant PERFORMANCE-FEE-RATE u200) ;; 2% performance fee
(define-constant MIN-DEPOSIT u100000) ;; Minimum 0.1 STX deposit
(define-constant REBALANCE-THRESHOLD u500) ;; 5% threshold for rebalancing
(define-constant COOLDOWN-PERIOD u144) ;; 1 day cooldown period
(define-constant BASIS-POINTS u10000) ;; 100% = 10000 basis points

;; Yield calculation constants
(define-constant YIELD-MULTIPLIER u1000000) ;; Precision multiplier for yield calculations
(define-constant MAX-SLIPPAGE u500) ;; Maximum 5% slippage allowed
(define-constant OPTIMAL-ALLOCATION-THRESHOLD u100) ;; 1% threshold for optimal allocation

;; ===== DATA VARIABLES =====

;; Global contract state
(define-data-var total-value-locked uint u0)
(define-data-var total-fees-collected uint u0)
(define-data-var next-pool-id uint u1)
(define-data-var next-strategy-id uint u1)
(define-data-var contract-paused bool false)
(define-data-var auto-rebalance-enabled bool true)

;; ===== DATA MAPS =====

;; Yield farming pool configurations
(define-map yield-pools
  { pool-id: uint }
  {
    name: (string-utf8 50),
    total-deposits: uint,
    current-yield-rate: uint, ;; APY scaled by YIELD-MULTIPLIER
    max-capacity: uint,
    strategy-id: uint,
    fee-rate: uint, ;; Basis points
    is-active: bool,
    created-block: uint,
    last-rebalance: uint
  }
)

;; User deposit tracking
(define-map user-deposits
  { user: principal, pool-id: uint }
  {
    amount: uint,
    entry-block: uint,
    entry-yield-rate: uint,
    accumulated-yield: uint,
    last-claim-block: uint,
    cooldown-end: uint
  }
)

;; Yield strategies configuration
(define-map yield-strategies
  { strategy-id: uint }
  {
    name: (string-utf8 50),
    base-yield: uint,
    risk-level: uint, ;; 1 = low, 2 = medium, 3 = high
    allocation-weight: uint, ;; Weight for allocation algorithm
    is-active: bool,
    total-allocated: uint
  }
)

;; Pool performance metrics
(define-map pool-performance
  { pool-id: uint }
  {
    total-yield-generated: uint,
    total-users: uint,
    average-deposit-size: uint,
    performance-score: uint, ;; Performance ranking score
    last-performance-update: uint
  }
)

;; User total positions across all pools
(define-map user-positions
  { user: principal }
  {
    total-deposited: uint,
    total-yield-earned: uint,
    active-pools: uint,
    last-activity-block: uint
  }
)

;; Fee collection tracking
(define-map fee-collections
  { pool-id: uint }
  {
    management-fees: uint,
    performance-fees: uint,
    total-collected: uint,
    last-collection-block: uint
  }
)

;; ===== PRIVATE FUNCTIONS =====

;; Calculate optimal yield for a given amount
(define-private (calculate-optimal-yield (amount uint) (pool-id uint))
  (let (
    (pool-info (unwrap! (map-get? yield-pools { pool-id: pool-id }) u0))
    (strategy-info (unwrap! (map-get? yield-strategies { strategy-id: (get strategy-id pool-info) }) u0))
    (current-yield-rate (get current-yield-rate pool-info))
    (base-yield (get base-yield strategy-info))
  )
    ;; Calculate yield based on amount and current rate
    (/ (* amount current-yield-rate) YIELD-MULTIPLIER)
  )
)

;; Calculate management fees
(define-private (calculate-management-fee (amount uint) (pool-id uint))
  (let (
    (pool-info (unwrap! (map-get? yield-pools { pool-id: pool-id }) u0))
    (fee-rate (get fee-rate pool-info))
  )
    (/ (* amount fee-rate) BASIS-POINTS)
  )
)

;; Calculate performance fees on yield
(define-private (calculate-performance-fee (yield-amount uint))
  (/ (* yield-amount PERFORMANCE-FEE-RATE) BASIS-POINTS)
)

;; Update pool performance metrics
(define-private (update-pool-performance (pool-id uint) (new-deposit uint))
  (let (
    (current-perf (default-to 
                    { total-yield-generated: u0, total-users: u0, average-deposit-size: u0, performance-score: u0, last-performance-update: u0 }
                    (map-get? pool-performance { pool-id: pool-id })))
    (pool-info (unwrap! (map-get? yield-pools { pool-id: pool-id }) false))
    (total-deposits (get total-deposits pool-info))
    (total-users (get total-users current-perf))
  )
    (map-set pool-performance
      { pool-id: pool-id }
      (merge current-perf {
        total-users: (if (> new-deposit u0) (+ total-users u1) total-users),
        average-deposit-size: (if (> total-users u0) (/ total-deposits total-users) u0),
        last-performance-update: block-height
      })
    )
    true
  )
)

;; Check if rebalancing is needed
(define-private (needs-rebalancing (pool-id uint))
  (let (
    (pool-info (unwrap! (map-get? yield-pools { pool-id: pool-id }) false))
    (blocks-since-rebalance (- block-height (get last-rebalance pool-info)))
  )
    (>= blocks-since-rebalance COOLDOWN-PERIOD)
  )
)

;; Calculate allocation weights for rebalancing
(define-private (calculate-allocation-weight (strategy-id uint))
  (let (
    (strategy-info (unwrap! (map-get? yield-strategies { strategy-id: strategy-id }) u0))
  )
    (* (get base-yield strategy-info) (get allocation-weight strategy-info))
  )
)

;; Validate withdrawal conditions
(define-private (can-withdraw (user principal) (pool-id uint))
  (let (
    (deposit-info (unwrap! (map-get? user-deposits { user: user, pool-id: pool-id }) false))
    (cooldown-end (get cooldown-end deposit-info))
  )
    (>= block-height cooldown-end)
  )
)

;; ===== ADMIN FUNCTIONS =====

;; Create a new yield farming pool
(define-public (create-yield-pool (name (string-utf8 50)) (max-capacity uint) (strategy-id uint) (fee-rate uint))
  (let (
    (pool-id (var-get next-pool-id))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (< pool-id MAX-POOLS) ERR-POOL-FULL)
    (asserts! (> max-capacity u0) ERR-INVALID-AMOUNT)
    (asserts! (<= fee-rate (* BASE-FEE-RATE u3)) ERR-INVALID-FEE) ;; Max 3% fee
    
    ;; Verify strategy exists
    (unwrap! (map-get? yield-strategies { strategy-id: strategy-id }) ERR-INVALID-STRATEGY)
    
    ;; Create pool
    (map-set yield-pools
      { pool-id: pool-id }
      {
        name: name,
        total-deposits: u0,
        current-yield-rate: u0,
        max-capacity: max-capacity,
        strategy-id: strategy-id,
        fee-rate: fee-rate,
        is-active: true,
        created-block: block-height,
        last-rebalance: block-height
      }
    )
    
    ;; Initialize performance tracking
    (map-set pool-performance
      { pool-id: pool-id }
      {
        total-yield-generated: u0,
        total-users: u0,
        average-deposit-size: u0,
        performance-score: u0,
        last-performance-update: block-height
      }
    )
    
    ;; Initialize fee collection
    (map-set fee-collections
      { pool-id: pool-id }
      {
        management-fees: u0,
        performance-fees: u0,
        total-collected: u0,
        last-collection-block: block-height
      }
    )
    
    ;; Increment pool counter
    (var-set next-pool-id (+ pool-id u1))
    
    (ok pool-id)
  )
)

;; Create a new yield strategy
(define-public (create-yield-strategy (name (string-utf8 50)) (base-yield uint) (risk-level uint) (allocation-weight uint))
  (let (
    (strategy-id (var-get next-strategy-id))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (> base-yield u0) ERR-INVALID-AMOUNT)
    (asserts! (and (>= risk-level u1) (<= risk-level u3)) ERR-INVALID-STRATEGY)
    (asserts! (> allocation-weight u0) ERR-INVALID-AMOUNT)
    
    (map-set yield-strategies
      { strategy-id: strategy-id }
      {
        name: name,
        base-yield: base-yield,
        risk-level: risk-level,
        allocation-weight: allocation-weight,
        is-active: true,
        total-allocated: u0
      }
    )
    
    (var-set next-strategy-id (+ strategy-id u1))
    
    (ok strategy-id)
  )
)

;; Update pool yield rate (admin only)
(define-public (update-pool-yield-rate (pool-id uint) (new-rate uint))
  (let (
    (pool-info (unwrap! (map-get? yield-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (> new-rate u0) ERR-INVALID-AMOUNT)
    
    (map-set yield-pools
      { pool-id: pool-id }
      (merge pool-info {
        current-yield-rate: new-rate
      })
    )
    
    (ok true)
  )
)

;; Toggle pool status (admin only)
(define-public (toggle-pool-status (pool-id uint))
  (let (
    (pool-info (unwrap! (map-get? yield-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    
    (map-set yield-pools
      { pool-id: pool-id }
      (merge pool-info {
        is-active: (not (get is-active pool-info))
      })
    )
    
    (ok (not (get is-active pool-info)))
  )
)

;; Toggle auto-rebalancing
(define-public (toggle-auto-rebalance)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set auto-rebalance-enabled (not (var-get auto-rebalance-enabled)))
    (ok (var-get auto-rebalance-enabled))
  )
)

;; ===== PUBLIC YIELD FARMING FUNCTIONS =====

;; Deposit tokens into a yield pool
(define-public (deposit-tokens (pool-id uint) (amount uint))
  (let (
    (pool-info (unwrap! (map-get? yield-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
    (current-deposit (map-get? user-deposits { user: tx-sender, pool-id: pool-id }))
    (user-pos (default-to { total-deposited: u0, total-yield-earned: u0, active-pools: u0, last-activity-block: u0 }
                          (map-get? user-positions { user: tx-sender })))
    (management-fee (calculate-management-fee amount pool-id))
    (net-deposit (- amount management-fee))
  )
    ;; Validations
    (asserts! (not (var-get contract-paused)) ERR-POOL-CLOSED)
    (asserts! (get is-active pool-info) ERR-POOL-CLOSED)
    (asserts! (>= amount MIN-DEPOSIT) ERR-INVALID-AMOUNT)
    (asserts! (<= (+ (get total-deposits pool-info) net-deposit) (get max-capacity pool-info)) ERR-POOL-FULL)
    
    ;; Handle existing vs new deposits
    (match current-deposit
      existing-deposit
      ;; Update existing deposit
      (map-set user-deposits
        { user: tx-sender, pool-id: pool-id }
        (merge existing-deposit {
          amount: (+ (get amount existing-deposit) net-deposit),
          cooldown-end: (+ block-height COOLDOWN-PERIOD)
        })
      )
      ;; Create new deposit
      (begin
        (map-set user-deposits
          { user: tx-sender, pool-id: pool-id }
          {
            amount: net-deposit,
            entry-block: block-height,
            entry-yield-rate: (get current-yield-rate pool-info),
            accumulated-yield: u0,
            last-claim-block: block-height,
            cooldown-end: (+ block-height COOLDOWN-PERIOD)
          }
        )
        ;; Update user position tracking
        (map-set user-positions
          { user: tx-sender }
          (merge user-pos {
            active-pools: (+ (get active-pools user-pos) u1)
          })
        )
      )
    )
    
    ;; Update pool totals
    (map-set yield-pools
      { pool-id: pool-id }
      (merge pool-info {
        total-deposits: (+ (get total-deposits pool-info) net-deposit)
      })
    )
    
    ;; Update user position totals
    (map-set user-positions
      { user: tx-sender }
      (merge user-pos {
        total-deposited: (+ (get total-deposited user-pos) net-deposit),
        last-activity-block: block-height
      })
    )
    
    ;; Update global TVL
    (var-set total-value-locked (+ (var-get total-value-locked) net-deposit))
    
    ;; Collect management fee
    (let (
      (current-fees (default-to { management-fees: u0, performance-fees: u0, total-collected: u0, last-collection-block: u0 }
                                 (map-get? fee-collections { pool-id: pool-id })))
    )
      (map-set fee-collections
        { pool-id: pool-id }
        (merge current-fees {
          management-fees: (+ (get management-fees current-fees) management-fee),
          total-collected: (+ (get total-collected current-fees) management-fee),
          last-collection-block: block-height
        })
      )
    )
    
    ;; Update performance metrics
    (update-pool-performance pool-id net-deposit)
    
    ;; Update global fees
    (var-set total-fees-collected (+ (var-get total-fees-collected) management-fee))
    
    (ok net-deposit)
  )
)

;; Withdraw tokens from a yield pool
(define-public (withdraw-tokens (pool-id uint) (amount uint))
  (let (
    (pool-info (unwrap! (map-get? yield-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
    (deposit-info (unwrap! (map-get? user-deposits { user: tx-sender, pool-id: pool-id }) ERR-INSUFFICIENT-BALANCE))
    (user-pos (unwrap! (map-get? user-positions { user: tx-sender }) ERR-INSUFFICIENT-BALANCE))
    (deposited-amount (get amount deposit-info))
    (withdrawal-amount (if (is-eq amount u0) deposited-amount amount))
  )
    ;; Validations
    (asserts! (not (var-get contract-paused)) ERR-POOL-CLOSED)
    (asserts! (<= withdrawal-amount deposited-amount) ERR-INSUFFICIENT-BALANCE)
    (asserts! (can-withdraw tx-sender pool-id) ERR-COOLDOWN-ACTIVE)
    
    ;; Calculate and claim any pending yield first
    (let (
      (pending-yield (calculate-optimal-yield withdrawal-amount pool-id))
      (performance-fee (calculate-performance-fee pending-yield))
      (net-yield (- pending-yield performance-fee))
      (is-full-withdrawal (is-eq withdrawal-amount deposited-amount))
    )
      ;; Update or remove deposit record
      (if is-full-withdrawal
        (map-delete user-deposits { user: tx-sender, pool-id: pool-id })
        (map-set user-deposits
          { user: tx-sender, pool-id: pool-id }
          (merge deposit-info {
            amount: (- deposited-amount withdrawal-amount),
            accumulated-yield: u0,
            last-claim-block: block-height,
            cooldown-end: (+ block-height COOLDOWN-PERIOD)
          })
        )
      )
      
      ;; Update pool totals
      (map-set yield-pools
        { pool-id: pool-id }
        (merge pool-info {
          total-deposits: (- (get total-deposits pool-info) withdrawal-amount)
        })
      )
      
      ;; Update user positions
      (map-set user-positions
        { user: tx-sender }
        (merge user-pos {
          total-deposited: (- (get total-deposited user-pos) withdrawal-amount),
          total-yield-earned: (+ (get total-yield-earned user-pos) net-yield),
          active-pools: (if is-full-withdrawal (- (get active-pools user-pos) u1) (get active-pools user-pos)),
          last-activity-block: block-height
        })
      )
      
      ;; Update global TVL
      (var-set total-value-locked (- (var-get total-value-locked) withdrawal-amount))
      
      ;; Update performance fees
      (let (
        (current-fees (unwrap! (map-get? fee-collections { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
      )
        (map-set fee-collections
          { pool-id: pool-id }
          (merge current-fees {
            performance-fees: (+ (get performance-fees current-fees) performance-fee),
            total-collected: (+ (get total-collected current-fees) performance-fee)
          })
        )
      )
      
      (var-set total-fees-collected (+ (var-get total-fees-collected) performance-fee))
      
      (ok (+ withdrawal-amount net-yield))
    )
  )
)

;; Rebalance pool allocations for optimal yield
(define-public (rebalance-pool (pool-id uint))
  (let (
    (pool-info (unwrap! (map-get? yield-pools { pool-id: pool-id }) ERR-POOL-NOT-FOUND))
  )
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) (var-get auto-rebalance-enabled)) ERR-UNAUTHORIZED)
    (asserts! (needs-rebalancing pool-id) ERR-REBALANCE-NOT-NEEDED)
    (asserts! (get is-active pool-info) ERR-POOL-CLOSED)
    
    ;; Update last rebalance timestamp
    (map-set yield-pools
      { pool-id: pool-id }
      (merge pool-info {
        last-rebalance: block-height
      })
    )
    
    ;; Update strategy allocation based on performance
    (let (
      (strategy-info (unwrap! (map-get? yield-strategies { strategy-id: (get strategy-id pool-info) }) ERR-INVALID-STRATEGY))
      (new-allocation-weight (calculate-allocation-weight (get strategy-id pool-info)))
    )
      (map-set yield-strategies
        { strategy-id: (get strategy-id pool-info) }
        (merge strategy-info {
          allocation-weight: new-allocation-weight
        })
      )
    )
    
    (ok true)
  )
)

;; ===== READ-ONLY FUNCTIONS =====

;; Get pool information
(define-read-only (get-pool-info (pool-id uint))
  (map-get? yield-pools { pool-id: pool-id })
)

;; Get user deposit information
(define-read-only (get-user-deposit (user principal) (pool-id uint))
  (map-get? user-deposits { user: user, pool-id: pool-id })
)

;; Get yield strategy information
(define-read-only (get-strategy-info (strategy-id uint))
  (map-get? yield-strategies { strategy-id: strategy-id })
)

;; Get pool performance metrics
(define-read-only (get-pool-performance (pool-id uint))
  (map-get? pool-performance { pool-id: pool-id })
)

;; Get user total positions
(define-read-only (get-user-positions (user principal))
  (map-get? user-positions { user: user })
)

;; Calculate potential yield for amount
(define-read-only (calculate-potential-yield (pool-id uint) (amount uint))
  (match (map-get? yield-pools { pool-id: pool-id })
    pool-info (ok (calculate-optimal-yield amount pool-id))
    ERR-POOL-NOT-FOUND
  )
)

;; Get fee information for a pool
(define-read-only (get-fee-info (pool-id uint))
  (map-get? fee-collections { pool-id: pool-id })
)

;; Get global contract statistics
(define-read-only (get-global-stats)
  {
    total-value-locked: (var-get total-value-locked),
    total-fees-collected: (var-get total-fees-collected),
    total-pools: (- (var-get next-pool-id) u1),
    total-strategies: (- (var-get next-strategy-id) u1),
    contract-paused: (var-get contract-paused),
    auto-rebalance-enabled: (var-get auto-rebalance-enabled)
  }
)
