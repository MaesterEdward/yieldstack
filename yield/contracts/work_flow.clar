;; Yield Farming Protocol Improved

(define-constant protocol-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-invalid-proof (err u101))
(define-constant err-invalid-sequence (err u102))
(define-constant err-protocol-paused (err u103))
(define-constant err-unauthorized-farm (err u104))
(define-constant err-stake-expired (err u105))
(define-constant err-insufficient-stake (err u106))
(define-constant err-invalid-parameter (err u107))
(define-constant err-invalid-yield-rate (err u109))

;; Data Variables
(define-data-var protocol-paused bool false)
(define-map sequence-registry principal uint)
(define-map yield-farms principal {
    efficiency: uint, 
    total-staked: uint, 
    enabled: bool, 
    min-stake: uint,
    yield-rate: uint,
    last-harvest-time: uint
})

(define-map stake-registry 
    uint 
    {staker: principal, 
     farm-id: (string-ascii 64),
     sequence: uint,
     timestamp: uint,
     proof: (buff 65),
     amount: uint,
     confirmed: bool,
     yield-harvested: uint})

(define-map farmer-analytics
    principal
    {total-staked: uint,
     active-stakes: uint,
     total-yield: uint,
     last-activity: uint})

(define-data-var registry-index uint u0)
(define-data-var cooldown-period uint u144) ;; Default 24 hours (144 blocks)
(define-data-var max-min-stake uint u1000000) 
(define-data-var base-yield-rate uint u100) ;; Base yield rate (x100 for precision)

;; Read-only functions
(define-read-only (get-sequence (user principal))
    (default-to u0 (map-get? sequence-registry user)))

(define-read-only (is-paused)
    (var-get protocol-paused))

(define-read-only (get-farm-details (farm principal))
    (map-get? yield-farms farm))

(define-read-only (get-stake-details (stake-id uint))
    (map-get? stake-registry stake-id))

(define-read-only (get-farmer-stats (user principal))
    (default-to 
        {total-staked: u0, active-stakes: u0, total-yield: u0, last-activity: u0}
        (map-get? farmer-analytics user)))

(define-read-only (get-protocol-metrics)
    {total-stakes: (var-get registry-index),
     is-paused: (var-get protocol-paused),
     cooldown-period: (var-get cooldown-period),
     max-min-stake: (var-get max-min-stake),
     base-yield-rate: (var-get base-yield-rate)})

(define-read-only (calculate-yield (stake-id uint))
    (let ((stake (unwrap-panic (map-get? stake-registry stake-id)))
          (current-block block-height)
          (farm-data (unwrap-panic (get-farm-details tx-sender))))
        (if (get confirmed stake)
            (let ((time-staked (- current-block (get timestamp stake)))
                  (base-yield (* (get amount stake) (get yield-rate farm-data))))
                (/ (* base-yield time-staked) u10000))
            u0)))

;; Read-only functions for proof verification
(define-read-only (verify-proof (message (buff 32)) (proof (buff 65)) (staker principal))
    (let ((recovered-public-key (unwrap! (secp256k1-recover? message proof) false)))
        (is-eq (unwrap! (principal-of? recovered-public-key) false) staker)))

;; Private functions
(define-private (increment-sequence (user principal))
    (let ((current-sequence (get-sequence user)))
        (map-set sequence-registry 
            user 
            (+ current-sequence u1))))

(define-private (update-farm-metrics (farm principal) (stake-amount uint))
    (let ((current-metrics (unwrap-panic (get-farm-details farm))))
        (map-set yield-farms
            farm
            (merge current-metrics 
                  {efficiency: (+ (get efficiency current-metrics) u1),
                   total-staked: (+ (get total-staked current-metrics) stake-amount),
                   last-harvest-time: block-height}))))

(define-private (update-farmer-analytics (user principal) (amount uint) (is-stake bool))
    (let ((current-stats (get-farmer-stats user)))
        (map-set farmer-analytics
            user
            (merge current-stats
                  {total-staked: (+ (get total-staked current-stats) (if is-stake amount u0)),
                   active-stakes: (+ (get active-stakes current-stats) (if is-stake amount (- u0 amount))),
                   last-activity: block-height}))))

(define-private (update-farmer-yield (user principal) (yield-amount uint))
    (let ((current-stats (get-farmer-stats user)))
        (map-set farmer-analytics
            user
            (merge current-stats
                  {total-yield: (+ (get total-yield current-stats) yield-amount),
                   last-activity: block-height}))))

(define-private (validate-farm (farm-to-check principal))
    (is-some (get-farm-details farm-to-check)))

(define-private (validate-min-stake (min-stake uint))
    (<= min-stake (var-get max-min-stake)))

(define-private (validate-yield-rate (rate uint))
    (and (> rate u0) (<= rate u1000)))

;; Public functions
(define-public (register-farm (new-farm principal) (minimum-stake uint) (yield-rate uint))
    (begin
        (asserts! (is-eq protocol-owner tx-sender) err-owner-only)
        (asserts! (not (validate-farm new-farm)) err-invalid-parameter)
        (asserts! (validate-min-stake minimum-stake) err-invalid-parameter)
        (asserts! (validate-yield-rate yield-rate) err-invalid-yield-rate)
        (ok (map-set yield-farms
            new-farm
            {efficiency: u0,
             total-staked: u0,
             enabled: true,
             min-stake: minimum-stake,
             yield-rate: yield-rate,
             last-harvest-time: block-height}))))

(define-public (toggle-pause)
    (begin
        (asserts! (is-eq protocol-owner tx-sender) err-owner-only)
        (ok (var-set protocol-paused (not (var-get protocol-paused))))))

(define-public (set-cooldown-period (new-period uint))
    (begin
        (asserts! (is-eq protocol-owner tx-sender) err-owner-only)
        (asserts! (> new-period u0) err-invalid-parameter)
        (ok (var-set cooldown-period new-period))))

(define-public (set-max-min-stake (new-max-min-stake uint))
    (begin
        (asserts! (is-eq protocol-owner tx-sender) err-owner-only)
        (asserts! (> new-max-min-stake u0) err-invalid-parameter)
        (ok (var-set max-min-stake new-max-min-stake))))

(define-public (update-farm-status (target-farm principal) (enabled-status bool) (minimum-stake uint) (yield-rate uint))
    (begin
        (asserts! (is-eq protocol-owner tx-sender) err-owner-only)
        (asserts! (validate-farm target-farm) err-invalid-parameter)
        (asserts! (validate-min-stake minimum-stake) err-invalid-parameter)
        (asserts! (validate-yield-rate yield-rate) err-invalid-yield-rate)
        (let ((farm-data (unwrap-panic (get-farm-details target-farm))))
            (ok (map-set yield-farms
                target-farm
                (merge farm-data 
                       {enabled: enabled-status,
                        min-stake: minimum-stake,
                        yield-rate: yield-rate,
                        last-harvest-time: block-height}))))))

(define-public (create-stake 
    (farm-id (string-ascii 64))
    (proof (buff 65))
    (amount uint))
    (let
        ((staker tx-sender)
         (current-sequence (get-sequence staker))
         (message-hash (sha256 (concat (unwrap-panic (to-consensus-buff? farm-id))
                                     (concat (unwrap-panic (to-consensus-buff? current-sequence))
                                             (unwrap-panic (to-consensus-buff? amount)))))))
        (asserts! (not (var-get protocol-paused)) err-protocol-paused)
        (asserts! (> amount u0) err-invalid-parameter)
        (asserts! (verify-proof message-hash proof staker) err-invalid-proof)
        (map-set stake-registry
            (var-get registry-index)
            {staker: staker,
             farm-id: farm-id,
             sequence: current-sequence,
             timestamp: block-height,
             proof: proof,
             amount: amount,
             confirmed: false,
             yield-harvested: u0})
        
        ;; Update farmer analytics
        (update-farmer-analytics staker amount true)
        
        ;; Increment registry index
        (var-set registry-index (+ (var-get registry-index) u1))
        (ok true)))

(define-public (confirm-stake (registry-id uint))
    (let ((stake (unwrap-panic (map-get? stake-registry registry-id)))
          (farm tx-sender)
          (farm-data (unwrap! (get-farm-details farm) err-unauthorized-farm))
          (current-height block-height))
        (asserts! (not (var-get protocol-paused)) err-protocol-paused)
        (asserts! (get enabled farm-data) err-unauthorized-farm)
        (asserts! (not (get confirmed stake)) err-invalid-sequence)
        (asserts! (<= (- current-height (get timestamp stake)) (var-get cooldown-period)) err-stake-expired)
        (asserts! (>= (get amount stake) (get min-stake farm-data)) err-insufficient-stake)
        
        ;; Process the stake
        (map-set stake-registry
            registry-id
            (merge stake {confirmed: true}))
        
        ;; Update sequence and farm stats
        (increment-sequence (get staker stake))
        (update-farm-metrics farm (get amount stake))
        (ok true)))

(define-public (cancel-stake (registry-id uint))
    (let ((stake (unwrap-panic (map-get? stake-registry registry-id)))
          (staker tx-sender))
        (asserts! (is-eq staker (get staker stake)) err-owner-only)
        (asserts! (not (get confirmed stake)) err-invalid-sequence)
        
        ;; Cancel the stake
        (map-set stake-registry
            registry-id
            (merge stake {confirmed: true}))
        
        ;; Update farmer analytics
        (update-farmer-analytics staker (get amount stake) false)
        
        ;; Update sequence
        (increment-sequence staker)
        (ok true)))

(define-public (harvest-yield (stake-id uint))
    (let ((stake (unwrap-panic (map-get? stake-registry stake-id)))
          (staker tx-sender)
          (yield-amount (calculate-yield stake-id)))
        (asserts! (is-eq staker (get staker stake)) err-owner-only)
        (asserts! (get confirmed stake) err-invalid-parameter)
        
        ;; Update yield harvested
        (map-set stake-registry
            stake-id
            (merge stake {yield-harvested: (+ (get yield-harvested stake) yield-amount)}))
        
        ;; Update farmer analytics
        (update-farmer-yield staker yield-amount)
        
        (ok yield-amount)))