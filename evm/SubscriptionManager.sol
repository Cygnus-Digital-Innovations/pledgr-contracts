// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SubscriptionManager
 * @notice Manages subscription metadata and state - does NOT process payments
 * @dev Data layer for subscriptions, payment processing happens in PaymentProcessor
 */
contract SubscriptionManager is Ownable {
    enum SubscriptionStatus {
        Active, // 0
        Cancelled // 1
    }

    // Split strategies (business flexibility)
    enum SplitStrategy {
        Strategy100_0, // 0 - 100% creator, 0% platform (free tier)
        Strategy96_4, // 1 - 96% creator, 4% platform
        Strategy95_5, // 2 - 95% creator, 5% platform (default)
        Strategy94_6, // 3 - 94% creator, 6% platform
        Strategy93_7, // 4 - 93% creator, 7% platform
        Strategy90_10 // 5 - 90% creator, 10% platform
    }

    // Split strategy configuration
    struct SplitConfig {
        uint16 creatorBps; // Creator percentage in basis points
        uint16 platformBps; // Platform percentage in basis points
        bool isActive; // Whether this strategy is active
        string name; // Strategy name for reference
    }

    // Mapping of strategies to their configurations
    mapping(SplitStrategy => SplitConfig) public splitStrategies;

    // Default strategy
    SplitStrategy public defaultStrategy = SplitStrategy.Strategy95_5;

    struct Subscription {
        bytes32 subscriptionId;
        address payer; // Fan wallet (PDF compliant)
        address creator; // Payout wallet (immutable per subscription)
        address token; // Stable coin token address (immutable per subscription)
        uint96 price; // Per period, token units (changes only via buyer re-consent)
        uint16 platformFeeBps; // Default 500 = 5%, customizable per tier at creation (immutable per subscription)
        SplitStrategy splitStrategy; // Revenue split strategy (immutable per subscription)
        uint32 periodSecs;
        uint40 nextDue;
        uint40 createdAt;
        uint40 lastCharged;
        uint8 status; // 0=Active, 1=Cancelled
        uint256 totalPaid;
        uint256 paymentCount;
        uint256 trialEndDate; // 0 if no trial
    }

    // Storage
    mapping(bytes32 => Subscription) internal subscriptions;
    mapping(address => bytes32[]) public userSubscriptions;
    mapping(address => bytes32[]) public creatorSubscriptions;

    // Global stats
    uint256 public totalSubscriptions;
    bool public paused;

    // Authorized payment processor
    address public paymentProcessor;

    // Supported stable coin tokens (configurable and extensible)
    mapping(address => bool) public supportedTokens;
    address[] public tokenList;

    // Events (PDF compliant)
    event SubscriptionCreated(
        bytes32 indexed subscriptionId,
        address indexed creator,
        address indexed subscriber,
        uint256 amount,
        uint256 frequencyDays
    );

    event PaymentRecorded(
        bytes32 indexed subscriptionId,
        uint256 amount,
        uint256 totalPaid,
        uint256 paymentCount
    );

    event PaymentProcessorUpdated(
        address indexed oldProcessor,
        address indexed newProcessor
    );
    event PausedStatusUpdated(bool paused);

    event SubscriptionStatusChanged(
        bytes32 indexed subscriptionId,
        uint8 oldStatus,
        uint8 newStatus
    );
    event Cancelled(bytes32 indexed subscriptionId);

    // Token management events
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);

    modifier onlyPaymentProcessor() {
        require(msg.sender == paymentProcessor, "Only payment processor");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier onlyValidToken(address token) {
        require(supportedTokens[token], "Token not supported");
        _;
    }

    constructor(
        address _usdt,
        address _usdc,
        address _paymentProcessor
    ) Ownable(msg.sender) {
        require(_usdt != address(0), "Invalid USDT address");
        require(_usdc != address(0), "Invalid USDC address");
        require(
            _paymentProcessor != address(0),
            "Invalid payment processor address"
        );
        paymentProcessor = _paymentProcessor;

        // Initialize split strategies
        _initializeSplitStrategies();

        // Automatically add USDT and USDC as supported tokens
        supportedTokens[_usdt] = true;
        tokenList.push(_usdt);

        supportedTokens[_usdc] = true;
        tokenList.push(_usdc);
    }

    /**
     * @notice Initialize split strategies with predefined configurations
     */
    function _initializeSplitStrategies() internal {
        // Strategy 100-0: 100% creator, 0% platform (free tier)
        splitStrategies[SplitStrategy.Strategy100_0] = SplitConfig({
            creatorBps: 10000, // 100%
            platformBps: 0, // 0%
            isActive: true,
            name: "100-0 Split"
        });

        // Strategy 96-4: 96% creator, 4% platform
        splitStrategies[SplitStrategy.Strategy96_4] = SplitConfig({
            creatorBps: 9600, // 96%
            platformBps: 400, // 4%
            isActive: true,
            name: "96-4 Split"
        });

        // Strategy 95-5: 95% creator, 5% platform (default)
        splitStrategies[SplitStrategy.Strategy95_5] = SplitConfig({
            creatorBps: 9500, // 95%
            platformBps: 500, // 5%
            isActive: true,
            name: "95-5 Split"
        });

        // Strategy 94-6: 94% creator, 6% platform
        splitStrategies[SplitStrategy.Strategy94_6] = SplitConfig({
            creatorBps: 9400, // 94%
            platformBps: 600, // 6%
            isActive: true,
            name: "94-6 Split"
        });

        // Strategy 93-7: 93% creator, 7% platform
        splitStrategies[SplitStrategy.Strategy93_7] = SplitConfig({
            creatorBps: 9300, // 93%
            platformBps: 700, // 7%
            isActive: true,
            name: "93-7 Split"
        });

        // Strategy 90-10: 90% creator, 10% platform
        splitStrategies[SplitStrategy.Strategy90_10] = SplitConfig({
            creatorBps: 9000, // 90%
            platformBps: 1000, // 10%
            isActive: true,
            name: "90-10 Split"
        });
    }

    /**
     * @notice Add a supported stable coin token
     * @param token Address of the stable coin token to add
     */
    function addSupportedToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(!supportedTokens[token], "Token already supported");

        supportedTokens[token] = true;
        tokenList.push(token);

        emit TokenAdded(token);
    }

    /**
     * @notice Remove a supported stable coin token
     * @param token Address of the stable coin token to remove
     */
    function removeSupportedToken(address token) external onlyOwner {
        require(supportedTokens[token], "Token not supported");

        supportedTokens[token] = false;

        // Remove from tokenList
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokenList[i] == token) {
                tokenList[i] = tokenList[tokenList.length - 1];
                tokenList.pop();
                break;
            }
        }

        emit TokenRemoved(token);
    }

    /**
     * @notice Get all supported tokens
     * @return Array of supported token addresses
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return tokenList;
    }

    /**
     * @notice Set authorized payment processor
     */
    function setPaymentProcessor(address _processor) external onlyOwner {
        require(_processor != address(0), "Invalid processor address");
        address oldProcessor = paymentProcessor;
        paymentProcessor = _processor;
        emit PaymentProcessorUpdated(oldProcessor, _processor);
    }

    /**
     * @notice Pause/unpause contract
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedStatusUpdated(_paused);
    }

    function createSubscription(
        address payer,
        address creator,
        uint96 price,
        address paymentToken,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 trialDays,
        bool /* chargeImmediately - deprecated */
    )
        external
        onlyPaymentProcessor
        whenNotPaused
        onlyValidToken(paymentToken)
        returns (bytes32 subscriptionId)
    {
        return
            _createSubscription(
                payer,
                creator,
                price,
                paymentToken,
                periodSecs,
                splitStrategy,
                trialDays
            );
    }

    function createScheduledSubscription(
        address payer,
        address creator,
        uint96 price,
        address paymentToken,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint40 startAt
    )
        external
        onlyPaymentProcessor
        whenNotPaused
        onlyValidToken(paymentToken)
        returns (bytes32 subscriptionId)
    {
        return
            _createSubscriptionWithStart(
                payer,
                creator,
                price,
                paymentToken,
                periodSecs,
                splitStrategy,
                0,
                startAt
            );
    }

    function _createSubscription(
        address payer,
        address creator,
        uint96 price,
        address paymentToken,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 trialDays
    ) internal returns (bytes32 subscriptionId) {
        uint40 nextDue = uint40(block.timestamp);
        uint256 trialEndDate = 0;

        if (trialDays > 0) {
            require(trialDays <= 365, "Trial period too long");
            trialEndDate = block.timestamp + (trialDays * 1 days);
            nextDue = uint40(trialEndDate);
        } else if (periodSecs > 0) {
            nextDue = uint40(block.timestamp + periodSecs);
        }

        return
            _createSubscriptionWithStart(
                payer,
                creator,
                price,
                paymentToken,
                periodSecs,
                splitStrategy,
                trialEndDate,
                nextDue
            );
    }

    function _createSubscriptionWithStart(
        address payer,
        address creator,
        uint96 price,
        address paymentToken,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 trialEndDate,
        uint40 nextDue
    ) internal returns (bytes32 subscriptionId) {
        require(payer != address(0), "Invalid payer address");
        require(creator != address(0), "Invalid creator address");
        require(price > 0, "Price must be greater than 0");
        require(
            splitStrategies[splitStrategy].isActive,
            "Split strategy not active"
        );
        require(supportedTokens[paymentToken], "Token not supported");

        subscriptionId = keccak256(
            abi.encodePacked(
                block.timestamp,
                payer,
                creator,
                totalSubscriptions
            )
        );

        SplitConfig memory splitConfig = splitStrategies[splitStrategy];

        subscriptions[subscriptionId] = Subscription({
            subscriptionId: subscriptionId,
            payer: payer,
            creator: creator,
            token: paymentToken,
            price: price,
            platformFeeBps: splitConfig.platformBps,
            splitStrategy: splitStrategy,
            periodSecs: periodSecs,
            nextDue: nextDue,
            createdAt: uint40(block.timestamp),
            lastCharged: 0,
            status: uint8(SubscriptionStatus.Active),
            totalPaid: 0,
            paymentCount: 0,
            trialEndDate: trialEndDate
        });

        userSubscriptions[payer].push(subscriptionId);
        creatorSubscriptions[creator].push(subscriptionId);

        totalSubscriptions++;

        emit SubscriptionCreated(
            subscriptionId,
            creator,
            payer,
            price,
            periodSecs
        );

        return subscriptionId;
    }

    /**
     * @notice Record a payment (called by PaymentProcessor after successful payment)
     */
    function recordPayment(
        bytes32 subscriptionId,
        uint256 amount
    ) external onlyPaymentProcessor whenNotPaused {
        Subscription storage sub = subscriptions[subscriptionId];
        require(sub.createdAt > 0, "Subscription does not exist");
        require(
            sub.status == uint8(SubscriptionStatus.Active),
            "Subscription not active"
        );

        sub.totalPaid += amount;
        sub.paymentCount += 1;

        emit PaymentRecorded(
            subscriptionId,
            amount,
            sub.totalPaid,
            sub.paymentCount
        );
    }

    /**
     * @notice Cancel a subscription
     */
    function cancelSubscription(bytes32 subscriptionId) external {
        Subscription storage sub = subscriptions[subscriptionId];
        require(sub.createdAt > 0, "Subscription does not exist");
        require(
            sub.status == uint8(SubscriptionStatus.Active),
            "Subscription not active"
        );
        require(
            msg.sender == sub.payer ||
                msg.sender == sub.creator ||
                msg.sender == owner() ||
                msg.sender == paymentProcessor,
            "Not authorized to cancel"
        );

        sub.status = uint8(SubscriptionStatus.Cancelled);

        emit Cancelled(subscriptionId);
        emit SubscriptionStatusChanged(
            subscriptionId,
            uint8(SubscriptionStatus.Active),
            uint8(SubscriptionStatus.Cancelled)
        );
    }

    /**
     * @notice Get subscription data (for other contracts to read)
     */
    function getSubscriptionData(
        bytes32 subscriptionId
    )
        external
        view
        returns (
            address creator,
            address subscriber,
            uint256 amount,
            address paymentToken,
            uint8 status,
            uint256 nextPaymentDue,
            bool isOneTime
        )
    {
        Subscription memory sub = subscriptions[subscriptionId];
        require(sub.createdAt > 0, "Subscription does not exist");

        return (
            sub.creator,
            sub.payer,
            sub.price,
            sub.token,
            sub.status,
            sub.nextDue,
            sub.periodSecs == 0
        );
    }

    /**
     * @notice Check if payment is due
     */
    function isPaymentDue(bytes32 subscriptionId) external view returns (bool) {
        Subscription memory sub = subscriptions[subscriptionId];
        return
            sub.status == uint8(SubscriptionStatus.Active) &&
            block.timestamp >= sub.nextDue;
    }

    /**
     * @notice Get user's subscriptions
     */
    function getUserSubscriptions(
        address user
    ) external view returns (bytes32[] memory) {
        return userSubscriptions[user];
    }

    /**
     * @notice Get creator's subscriptions
     */
    function getCreatorSubscriptions(
        address creator
    ) external view returns (bytes32[] memory) {
        return creatorSubscriptions[creator];
    }

    /**
     * @notice Get subscription renewal data (minimal for PaymentProcessor)
     */
    function getSubscriptionRenewalData(
        bytes32 subscriptionId
    )
        external
        view
        returns (
            address payer,
            uint8 splitStrategy,
            uint32 periodSecs,
            uint256 paymentCount,
            uint16 platformFeeBps
        )
    {
        Subscription storage s = subscriptions[subscriptionId];
        return (
            s.payer,
            uint8(s.splitStrategy),
            s.periodSecs,
            s.paymentCount,
            s.platformFeeBps
        );
    }

    /**
     * @notice Update renewal data after successful renewal
     */
    function updateRenewalData(
        bytes32 subscriptionId,
        uint40 lastCharged,
        uint40 nextDue
    ) external onlyPaymentProcessor whenNotPaused {
        Subscription storage sub = subscriptions[subscriptionId];
        require(sub.createdAt > 0, "Subscription does not exist");
        require(
            sub.status == uint8(SubscriptionStatus.Active),
            "Subscription not active"
        );
        require(
            lastCharged <= uint40(block.timestamp),
            "lastCharged cannot be in the future"
        );
        require(nextDue > lastCharged, "nextDue must be after lastCharged");
        sub.lastCharged = lastCharged;
        sub.nextDue = nextDue;
    }

    /**
     * @notice Check if already charged this period
     */
    function isAlreadyChargedThisPeriod(
        bytes32 subscriptionId
    ) external view returns (bool) {
        Subscription memory sub = subscriptions[subscriptionId];
        if (sub.lastCharged == 0) return false;
        if (sub.periodSecs == 0) return true;

        return (block.timestamp - sub.lastCharged) < sub.periodSecs;
    }

    /**
     * @notice Get split strategy configuration
     * @param strategy The split strategy
     * @return creatorBps Creator basis points
     * @return platformBps Platform basis points
     * @return isActive Whether the strategy is active
     * @return name Strategy name
     */
    function getSplitStrategy(
        uint8 strategy
    )
        external
        view
        returns (
            uint16 creatorBps,
            uint16 platformBps,
            bool isActive,
            string memory name
        )
    {
        require(
            strategy <= uint8(SplitStrategy.Strategy90_10),
            "Invalid strategy"
        );
        SplitConfig memory config = splitStrategies[SplitStrategy(strategy)];
        return (
            config.creatorBps,
            config.platformBps,
            config.isActive,
            config.name
        );
    }

    /**
     * @notice Returns the uint8 value for Strategy95_5
     */
    function STRATEGY_95_5() external pure returns (uint8) {
        return uint8(SplitStrategy.Strategy95_5);
    }

    // ==================== AUDIT DESIGN DECISIONS ====================
    //
    // Pause independence: SubscriptionManager uses its own pause (bool paused) separate from PledgrPayments (OZ Pausable).
    // SubscriptionManager is the long-lived data layer. PledgrPayments may be upgraded by deploying a new version
    // and calling setPaymentProcessor to point here. Independent pause ensures the data layer remains stable
    // across payment processor upgrades without coupling lifecycle to the processor contract.
    //
    // cancelSubscription has no whenNotPaused: Intentional. Users must always be able to cancel subscriptions
    // and stop future charges, even during an emergency pause. This is a user-protection guarantee.
    //
    // Split strategies are immutable post-deployment: Initialized in constructor via _initializeSplitStrategies().
    // No updateSplitStrategy or setDefaultStrategy function exists. This prevents admin manipulation of
    // creator revenue splits after deployment. The 6 strategies (100/0, 96/4, 95/5, 94/6, 93/7, 90/10) are final.
    //
    // Subscription arrays (userSubscriptions, creatorSubscriptions) are append-only by design.
    // Cancelled subscriptions are not removed. Off-chain indexing via events is the primary query mechanism.
    // On-chain getters exist for convenience but may become gas-expensive for high-volume creators.
    //
    // Token removal: Removing a supported token does not cancel existing subscriptions.
    // Existing subscriptions with a removed token will fail renewal at PledgrPayments' supportedTokens check
    // and auto-cancel after the 7-day grace period. This is graceful deprecation by design.
    //
    // updateRenewalData invariants: lastCharged must be <= block.timestamp, nextDue must be > lastCharged.
    // These are enforced on-chain. The payment processor must always pair recordPayment with updateRenewalData
    // for correct subscription state. One-time subscriptions (periodSecs == 0) rely on lastCharged being set
    // to prevent isAlreadyChargedThisPeriod from allowing re-charge.
    //
    // setPaymentProcessor: Allows re-assignment by owner for upgrading to a new PledgrPayments contract.
    // This is intentional since contracts are non-upgradeable. PledgrPayments.initialize() is one-shot,
    // but SubscriptionManager.setPaymentProcessor() is re-callable to support processor upgrades.
}
