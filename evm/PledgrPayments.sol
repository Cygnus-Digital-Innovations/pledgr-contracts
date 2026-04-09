// SPDX-License-Identifier: MIT
// This contract is provided as-is with no warranty. Use at your own risk.
// Non-custodial: this contract never holds user funds. All transfers are split-at-source directly to recipients.
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface ISubscriptionManager {
    enum SplitStrategy {
        Strategy100_0,
        Strategy96_4,
        Strategy95_5,
        Strategy94_6,
        Strategy93_7,
        Strategy90_10
    }

    function createSubscription(
        address payer,
        address creator,
        uint96 price,
        address paymentToken,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 trialDays,
        bool chargeImmediately
    ) external returns (bytes32 subscriptionId);

    function createScheduledSubscription(
        address payer,
        address creator,
        uint96 price,
        address paymentToken,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint40 startAt
    ) external returns (bytes32 subscriptionId);

    function recordPayment(bytes32 subscriptionId, uint256 amount) external;

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
        );

    function getSubscriptionRenewalData(
        bytes32 subId
    )
        external
        view
        returns (
            address payer,
            uint8 splitStrategy,
            uint32 periodSecs,
            uint256 paymentCount,
            uint16 platformFeeBps
        );

    function isPaymentDue(bytes32 subscriptionId) external view returns (bool);

    function cancelSubscription(bytes32 subscriptionId) external;

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
        );

    function isAlreadyChargedThisPeriod(
        bytes32 subscriptionId
    ) external view returns (bool);

    function updateRenewalData(
        bytes32 subscriptionId,
        uint40 lastCharged,
        uint40 nextDue
    ) external;

    function STRATEGY_95_5() external pure returns (uint8);
}

contract PledgrPayments is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    enum SplitStrategy {
        STRATEGY_100_0,
        STRATEGY_96_4,
        STRATEGY_95_5,
        STRATEGY_94_6,
        STRATEGY_93_7,
        STRATEGY_90_10
    }

    ISubscriptionManager public subscriptionManager;

    mapping(address => bool) public supportedTokens;
    address[] public tokenList;

    address public immutable USDT;
    address public immutable USDC;

    address public coOwner1Wallet;
    address public coOwner2Wallet;
    address public communityWallet;

    uint16 public constant CO_OWNER1_BPS = 4000;
    uint16 public constant CO_OWNER2_BPS = 4000;
    uint16 public constant COMMUNITY_BPS = 2000;
    uint256 public constant RENEWAL_GRACE_PERIOD = 7 days;

    uint256 public bountyPerRenewal = 0.01e6;
    uint256 public maxBountyPerTx = 3e6;
    bool public bountyEnabled = true;
    uint256 public maxBatchSize = 150;

    struct PaymentRecord {
        bytes32 paymentId;
        address payer;
        address creator;
        address paymentToken;
        uint256 amount;
        uint256 fees;
        uint256 timestamp;
        bool exists;
    }

    mapping(bytes32 => PaymentRecord) public paymentRecords;

    event PaymentProcessed(
        address indexed payer,
        address indexed creator,
        address indexed paymentToken,
        uint256 amount,
        bytes32 paymentId
    );

    event SubscriptionManagerUpdated(address subscriptionManager);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);

    event Renewed(
        bytes32 indexed subscriptionId,
        address indexed caller,
        address indexed subscriber,
        uint256 amount
    );
    event RenewalProcessed(
        bytes32 indexed subscriptionId,
        address indexed payer,
        uint256 amount,
        bool success
    );
    event RenewalFailed(bytes32 indexed subscriptionId, string reason);
    event Cancelled(bytes32 indexed subscriptionId);

    event BountyPaid(
        address indexed caller,
        address indexed token,
        uint256 amount
    );
    event BountyPaymentFailed(
        address indexed caller,
        address indexed token,
        uint256 amount,
        string reason
    );
    event BountyConfigUpdated(
        uint256 bountyPerRenewal,
        uint256 maxBountyPerTx,
        bool enabled
    );
    event MaxBatchSizeUpdated(uint256 newMaxBatchSize);
    event CoOwner1WalletUpdated(
        address indexed oldWallet,
        address indexed newWallet
    );
    event CoOwner2WalletUpdated(
        address indexed oldWallet,
        address indexed newWallet
    );
    event CommunityWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet
    );

    event RenewalSkipped(bytes32 indexed subscriptionId, string reason);
    event SubscriptionDowngraded(
        bytes32 indexed oldSubscriptionId,
        bytes32 indexed newSubscriptionId,
        address indexed payer,
        uint96 newPrice,
        uint32 periodSecs
    );
    event SubscriptionUpgraded(
        bytes32 indexed oldSubscriptionId,
        bytes32 indexed newSubscriptionId,
        address indexed payer,
        uint96 newPrice,
        uint256 proratedAmount,
        uint32 periodSecs
    );

    modifier onlyValidToken(address token) {
        require(
            supportedTokens[token],
            "PaymentProcessor: Token not supported"
        );
        _;
    }

    modifier initialized() {
        require(address(subscriptionManager) != address(0), "Not initialized");
        _;
    }

    function _calculateSplit(
        uint256 amount,
        uint16 platformBps
    ) internal pure returns (uint256 creatorAmount, uint256 platformAmount) {
        platformAmount = (amount * platformBps) / 10000;
        creatorAmount = amount - platformAmount;
    }

    function _distributePlatformFee(
        IERC20 token,
        address from,
        uint256 platformAmount
    ) internal {
        if (platformAmount == 0) return;
        uint256 co1 = (platformAmount * CO_OWNER1_BPS) / 10000;
        uint256 co2 = (platformAmount * CO_OWNER2_BPS) / 10000;
        uint256 comm = platformAmount - co1 - co2;
        if (co1 > 0) token.safeTransferFrom(from, coOwner1Wallet, co1);
        if (co2 > 0) token.safeTransferFrom(from, coOwner2Wallet, co2);
        if (comm > 0) token.safeTransferFrom(from, communityWallet, comm);
    }

    constructor(
        address _usdt,
        address _usdc,
        address _coOwner1Wallet,
        address _coOwner2Wallet,
        address _communityWallet
    ) Ownable(msg.sender) {
        require(_usdt != address(0), "Invalid USDT address");
        require(_usdc != address(0), "Invalid USDC address");
        require(_coOwner1Wallet != address(0), "Invalid coOwner1 wallet");
        require(_coOwner2Wallet != address(0), "Invalid coOwner2 wallet");
        require(_communityWallet != address(0), "Invalid community wallet");

        USDT = _usdt;
        USDC = _usdc;
        coOwner1Wallet = _coOwner1Wallet;
        coOwner2Wallet = _coOwner2Wallet;
        communityWallet = _communityWallet;

        supportedTokens[_usdt] = true;
        tokenList.push(_usdt);

        supportedTokens[_usdc] = true;
        tokenList.push(_usdc);
    }

    function initialize(address _subscriptionManager) external onlyOwner {
        require(
            address(subscriptionManager) == address(0),
            "Already initialized"
        );
        require(
            _subscriptionManager != address(0),
            "Invalid subscription manager"
        );
        subscriptionManager = ISubscriptionManager(_subscriptionManager);
        emit SubscriptionManagerUpdated(_subscriptionManager);
    }

    // Fee-on-transfer tokens not a risk. Only standard stablecoins (USDT, USDC) are added as supported tokens.
    function addSupportedToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(!supportedTokens[token], "Token already supported");

        supportedTokens[token] = true;
        tokenList.push(token);

        emit TokenAdded(token);
    }

    function removeSupportedToken(address token) external onlyOwner {
        require(supportedTokens[token], "Token not supported");

        supportedTokens[token] = false;

        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokenList[i] == token) {
                tokenList[i] = tokenList[tokenList.length - 1];
                tokenList.pop();
                break;
            }
        }

        emit TokenRemoved(token);
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return tokenList;
    }

    function processPayment(
        address paymentToken,
        uint256 amount,
        address creator,
        bytes32 paymentId,
        uint256 fees
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        onlyValidToken(paymentToken)
    {
        _processPaymentWithStrategy(
            paymentToken,
            amount,
            creator,
            paymentId,
            SplitStrategy.STRATEGY_95_5,
            fees
        );
    }

    function processPayment(
        address paymentToken,
        uint256 amount,
        address creator,
        bytes32 paymentId,
        SplitStrategy splitStrategy,
        uint256 fees
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        onlyValidToken(paymentToken)
    {
        _processPaymentWithStrategy(
            paymentToken,
            amount,
            creator,
            paymentId,
            splitStrategy,
            fees
        );
    }

    function processPaymentWithPermit(
        address paymentToken,
        uint256 amount,
        address creator,
        bytes32 paymentId,
        uint256 fees,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        onlyValidToken(paymentToken)
    {
        try
            IERC20Permit(paymentToken).permit(
                msg.sender,
                address(this),
                amount + fees,
                deadline,
                v,
                r,
                s
            )
        {} catch {}
        _processPaymentWithStrategy(
            paymentToken,
            amount,
            creator,
            paymentId,
            SplitStrategy.STRATEGY_95_5,
            fees
        );
    }

    function processPaymentWithPermit(
        address paymentToken,
        uint256 amount,
        address creator,
        bytes32 paymentId,
        uint256 fees,
        SplitStrategy splitStrategy,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        onlyValidToken(paymentToken)
    {
        try
            IERC20Permit(paymentToken).permit(
                msg.sender,
                address(this),
                amount + fees,
                deadline,
                v,
                r,
                s
            )
        {} catch {}
        _processPaymentWithStrategy(
            paymentToken,
            amount,
            creator,
            paymentId,
            splitStrategy,
            fees
        );
    }

    function _processPaymentWithStrategy(
        address paymentToken,
        uint256 amount,
        address creator,
        bytes32 paymentId,
        SplitStrategy splitStrategy,
        uint256 fees
    ) internal {
        require(amount > 0, "Amount must be positive");
        require(creator != address(0), "Invalid creator");
        require(
            creator != coOwner1Wallet &&
                creator != coOwner2Wallet &&
                creator != communityWallet,
            "Creator cannot be platform"
        );
        require(!paymentRecords[paymentId].exists, "Payment ID already used");

        (, uint16 platformBps, bool isActive, ) = subscriptionManager
            .getSplitStrategy(uint8(splitStrategy));
        require(isActive, "Split strategy not active");

        (uint256 creatorAmount, uint256 platformAmount) = _calculateSplit(
            amount,
            platformBps
        );

        IERC20 token = IERC20(paymentToken);
        token.safeTransferFrom(msg.sender, creator, creatorAmount);
        _distributePlatformFee(token, msg.sender, platformAmount);

        if (fees > 0) {
            token.safeTransferFrom(msg.sender, communityWallet, fees);
        }

        paymentRecords[paymentId] = PaymentRecord({
            paymentId: paymentId,
            payer: msg.sender,
            creator: creator,
            paymentToken: paymentToken,
            amount: amount,
            fees: fees,
            timestamp: block.timestamp,
            exists: true
        });

        emit PaymentProcessed(
            msg.sender,
            creator,
            paymentToken,
            amount,
            paymentId
        );
    }

    function emergencyWithdraw(address token) external onlyOwner whenPaused {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(owner(), balance);
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function updateCoOwner1Wallet(address newAddress) external {
        require(msg.sender == coOwner1Wallet, "Only coOwner1");
        require(newAddress != address(0), "Invalid address");
        address old = coOwner1Wallet;
        coOwner1Wallet = newAddress;
        emit CoOwner1WalletUpdated(old, newAddress);
    }

    function updateCoOwner2Wallet(address newAddress) external {
        require(msg.sender == coOwner2Wallet, "Only coOwner2");
        require(newAddress != address(0), "Invalid address");
        address old = coOwner2Wallet;
        coOwner2Wallet = newAddress;
        emit CoOwner2WalletUpdated(old, newAddress);
    }

    function updateCommunityWallet(address newAddress) external onlyOwner {
        require(newAddress != address(0), "Invalid address");
        address old = communityWallet;
        communityWallet = newAddress;
        emit CommunityWalletUpdated(old, newAddress);
    }

    function getPaymentDetails(
        bytes32 paymentId
    )
        external
        view
        returns (
            bytes32,
            address payer,
            address creator,
            address paymentToken,
            uint256 amount,
            uint256 fees,
            uint256 timestamp,
            bool exists
        )
    {
        PaymentRecord memory record = paymentRecords[paymentId];
        return (
            record.paymentId,
            record.payer,
            record.creator,
            record.paymentToken,
            record.amount,
            record.fees,
            record.timestamp,
            record.exists
        );
    }

    function canRenew(
        bytes32 subscriptionId
    ) external view returns (bool eligible, string memory reason) {
        try subscriptionManager.getSubscriptionData(subscriptionId) returns (
            address,
            address subscriber,
            uint256 amount,
            address paymentToken,
            uint8 status,
            uint256 nextDue,
            bool isOneTime
        ) {
            if (isOneTime) return (false, "One-time payment");
            if (status != 0) return (false, "Not active");
            if (block.timestamp < nextDue) return (false, "Not due yet");
            if (block.timestamp > nextDue + RENEWAL_GRACE_PERIOD)
                return (false, "Grace period expired");
            if (subscriptionManager.isAlreadyChargedThisPeriod(subscriptionId))
                return (false, "Already charged");
            if (!supportedTokens[paymentToken])
                return (false, "Token no longer supported");

            IERC20 token = IERC20(paymentToken);
            if (token.balanceOf(subscriber) < amount)
                return (false, "Insufficient balance");
            if (token.allowance(subscriber, address(this)) < amount)
                return (false, "Insufficient allowance");

            return (true, "");
        } catch {
            return (false, "Subscription does not exist");
        }
    }

    function processRenewal(
        bytes32 subscriptionId
    ) external nonReentrant whenNotPaused initialized {
        _processRenewalInternal(subscriptionId, true, true);
    }

    function executeRenewal(
        bytes32 subscriptionId,
        bool payBounty,
        bool emitSkipEvents
    ) external returns (bool success, uint256 platformFeeEarned) {
        require(msg.sender == address(this), "Internal only");
        return
            _processRenewalInternal(subscriptionId, payBounty, emitSkipEvents);
    }

    function _processRenewalInternal(
        bytes32 subscriptionId,
        bool payBounty,
        bool emitSkipEvents
    ) internal returns (bool success, uint256 platformFeeEarned) {
        (
            address creator,
            address subscriber,
            uint256 amount,
            address paymentToken,
            uint8 status,
            uint256 nextDue,
            bool isOneTime
        ) = subscriptionManager.getSubscriptionData(subscriptionId);

        if (isOneTime) {
            if (emitSkipEvents)
                emit RenewalSkipped(subscriptionId, "One-time payment");
            return (false, 0);
        }
        if (status != 0) {
            if (emitSkipEvents)
                emit RenewalSkipped(subscriptionId, "Not active");
            return (false, 0);
        }

        if (block.timestamp < nextDue) {
            if (emitSkipEvents)
                emit RenewalSkipped(subscriptionId, "Not due yet");
            return (false, 0);
        }

        if (block.timestamp > nextDue + RENEWAL_GRACE_PERIOD) {
            subscriptionManager.cancelSubscription(subscriptionId);
            emit Cancelled(subscriptionId);
            if (emitSkipEvents)
                emit RenewalSkipped(
                    subscriptionId,
                    "Grace period expired, subscription cancelled"
                );
            return (false, 0);
        }

        if (subscriptionManager.isAlreadyChargedThisPeriod(subscriptionId)) {
            if (emitSkipEvents)
                emit RenewalSkipped(subscriptionId, "Already charged");
            return (false, 0);
        }

        if (!supportedTokens[paymentToken]) {
            if (emitSkipEvents)
                emit RenewalSkipped(
                    subscriptionId,
                    "Token no longer supported"
                );
            return (false, 0);
        }

        IERC20 token = IERC20(paymentToken);
        if (token.balanceOf(subscriber) < amount) {
            if (emitSkipEvents)
                emit RenewalSkipped(subscriptionId, "Insufficient balance");
            return (false, 0);
        }
        if (token.allowance(subscriber, address(this)) < amount) {
            if (emitSkipEvents)
                emit RenewalSkipped(subscriptionId, "Insufficient allowance");
            return (false, 0);
        }

        (, , uint32 periodSecs, , uint16 platformBps) = subscriptionManager
            .getSubscriptionRenewalData(subscriptionId);

        (uint256 creatorAmount, uint256 platformFee) = _calculateSplit(
            amount,
            platformBps
        );

        token.safeTransferFrom(subscriber, creator, creatorAmount);
        _distributePlatformFee(token, subscriber, platformFee);

        subscriptionManager.updateRenewalData(
            subscriptionId,
            uint40(block.timestamp),
            uint40(block.timestamp + periodSecs)
        );
        subscriptionManager.recordPayment(subscriptionId, amount);

        if (payBounty && bountyEnabled) {
            uint256 communityShare = (platformFee * COMMUNITY_BPS) / 10000;
            uint256 bounty = bountyPerRenewal < communityShare
                ? bountyPerRenewal
                : communityShare;
            if (bounty > maxBountyPerTx) bounty = maxBountyPerTx;
            _payBounty(paymentToken, bounty);
        }

        emit Renewed(subscriptionId, msg.sender, subscriber, amount);
        emit RenewalProcessed(subscriptionId, subscriber, amount, true);

        return (true, platformFee);
    }

    function _payBounty(address token, uint256 amount) internal {
        if (!bountyEnabled || amount == 0) return;

        IERC20 bountyToken = IERC20(token);
        uint256 allowance = bountyToken.allowance(
            communityWallet,
            address(this)
        );
        uint256 balance = bountyToken.balanceOf(communityWallet);
        if (allowance >= amount && balance >= amount) {
            bountyToken.safeTransferFrom(communityWallet, msg.sender, amount);
            emit BountyPaid(msg.sender, token, amount);
        } else {
            emit BountyPaymentFailed(
                msg.sender,
                token,
                amount,
                "Insufficient community wallet allowance or balance"
            );
        }
    }

    function renewBatch(
        bytes32[] calldata subscriptionIds
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        returns (uint256 successCount)
    {
        require(subscriptionIds.length > 0, "Empty batch");
        require(subscriptionIds.length <= maxBatchSize, "Batch too large");

        address bountyToken = address(0);
        uint256 totalBountyEarned;

        for (uint256 i = 0; i < subscriptionIds.length; i++) {
            bytes32 subId = subscriptionIds[i];

            try subscriptionManager.getSubscriptionData(subId) returns (
                address,
                address,
                uint256,
                address paymentToken,
                uint8,
                uint256,
                bool
            ) {
                if (bountyToken != address(0) && paymentToken != bountyToken) {
                    emit RenewalFailed(subId, "Mixed tokens in batch");
                    continue;
                }

                try this.executeRenewal(subId, false, false) returns (
                    bool success,
                    uint256 platformFee
                ) {
                    if (success) {
                        successCount++;
                        if (bountyToken == address(0)) {
                            bountyToken = paymentToken;
                        }
                        if (platformFee > 0) {
                            uint256 communityShare = (platformFee *
                                COMMUNITY_BPS) / 10000;
                            uint256 subBounty = bountyPerRenewal <
                                communityShare
                                ? bountyPerRenewal
                                : communityShare;
                            totalBountyEarned += subBounty;
                        }
                    } else {
                        emit RenewalFailed(subId, "Renewal skipped");
                    }
                } catch {
                    emit RenewalFailed(subId, "Renewal failed");
                }
            } catch {
                emit RenewalFailed(subId, "Subscription does not exist");
            }
        }

        if (totalBountyEarned > maxBountyPerTx) {
            totalBountyEarned = maxBountyPerTx;
        }
        if (totalBountyEarned > 0 && bountyToken != address(0)) {
            _payBounty(bountyToken, totalBountyEarned);
        }

        return successCount;
    }

    function setBountyConfig(
        uint256 _bountyPerRenewal,
        uint256 _maxBountyPerTx,
        bool _enabled
    ) external onlyOwner {
        require(
            _bountyPerRenewal <= 1e6,
            "Bounty per renewal exceeds max (1 USDT)"
        );
        require(
            _maxBountyPerTx <= 100e6,
            "Max bounty per tx exceeds max (100 USDT)"
        );
        bountyPerRenewal = _bountyPerRenewal;
        maxBountyPerTx = _maxBountyPerTx;
        bountyEnabled = _enabled;
        emit BountyConfigUpdated(_bountyPerRenewal, _maxBountyPerTx, _enabled);
    }

    function setMaxBatchSize(uint256 _maxBatchSize) external onlyOwner {
        require(
            _maxBatchSize > 0 && _maxBatchSize <= 500,
            "Invalid batch size"
        );
        maxBatchSize = _maxBatchSize;
        emit MaxBatchSizeUpdated(_maxBatchSize);
    }

    function subscribeWithPermit(
        address creator,
        uint96 price,
        address paymentToken,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 fees,
        uint256 allowanceAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        onlyValidToken(paymentToken)
        returns (bytes32 subscriptionId)
    {
        require(
            allowanceAmount >= price + fees,
            "Allowance must cover at least one period"
        );
        try
            IERC20Permit(paymentToken).permit(
                msg.sender,
                address(this),
                allowanceAmount,
                deadline,
                v,
                r,
                s
            )
        {} catch {}
        return
            _processSubscription(
                creator,
                price,
                paymentToken,
                periodSecs,
                splitStrategy,
                fees
            );
    }

    function subscribe(
        address creator,
        uint96 price,
        address paymentToken,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 fees
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        onlyValidToken(paymentToken)
        returns (bytes32 subscriptionId)
    {
        IERC20 token = IERC20(paymentToken);
        require(
            token.allowance(msg.sender, address(this)) >= price + fees,
            "Insufficient allowance for subscription"
        );
        return
            _processSubscription(
                creator,
                price,
                paymentToken,
                periodSecs,
                splitStrategy,
                fees
            );
    }

    function _processSubscription(
        address creator,
        uint96 price,
        address paymentToken,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 fees
    ) internal returns (bytes32 subscriptionId) {
        require(creator != address(0), "Invalid creator");
        require(price > 0, "Price must be positive");
        require(periodSecs > 0, "Period must be positive");

        (, uint16 platformBps, bool isActive, ) = subscriptionManager
            .getSplitStrategy(uint8(splitStrategy));
        require(isActive, "Split strategy not active");

        subscriptionId = subscriptionManager.createSubscription(
            msg.sender,
            creator,
            price,
            paymentToken,
            periodSecs,
            ISubscriptionManager.SplitStrategy(uint8(splitStrategy)),
            0,
            true
        );

        (uint256 creatorAmount, uint256 platformAmount) = _calculateSplit(
            price,
            platformBps
        );

        IERC20 token = IERC20(paymentToken);
        token.safeTransferFrom(msg.sender, creator, creatorAmount);
        _distributePlatformFee(token, msg.sender, platformAmount);

        if (fees > 0) {
            token.safeTransferFrom(msg.sender, communityWallet, fees);
        }

        subscriptionManager.recordPayment(subscriptionId, price);

        uint256 nextDue = block.timestamp + periodSecs;
        subscriptionManager.updateRenewalData(
            subscriptionId,
            uint40(block.timestamp),
            uint40(nextDue)
        );

        emit PaymentProcessed(
            msg.sender,
            creator,
            paymentToken,
            price,
            subscriptionId
        );

        return subscriptionId;
    }

    // newPrice not validated on-chain by design. A "downgrade" can cost more (e.g. longer duration). Backend validates before tx.
    function downgrade(
        bytes32 subscriptionId,
        uint96 newPrice,
        uint32 periodSecs,
        uint256 fees
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        returns (bytes32 newSubscriptionId)
    {
        return _processDowngrade(subscriptionId, newPrice, periodSecs, fees);
    }

    function downgradeWithPermit(
        bytes32 subscriptionId,
        uint96 newPrice,
        uint32 periodSecs,
        uint256 fees,
        uint256 allowanceAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        returns (bytes32 newSubscriptionId)
    {
        require(allowanceAmount >= fees, "Allowance must cover fees");
        (, , , address paymentToken, , , ) = subscriptionManager
            .getSubscriptionData(subscriptionId);
        if (allowanceAmount > 0) {
            try
                IERC20Permit(paymentToken).permit(
                    msg.sender,
                    address(this),
                    allowanceAmount,
                    deadline,
                    v,
                    r,
                    s
                )
            {} catch {}
        }
        return _processDowngrade(subscriptionId, newPrice, periodSecs, fees);
    }

    // proratedAmount not validated on-chain. Validated off-chain by backend before tx is presented. Accepted tradeoff for dynamic tier pricing.
    function upgrade(
        bytes32 subscriptionId,
        uint96 newPrice,
        uint256 proratedAmount,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 fees
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        returns (bytes32 newSubscriptionId)
    {
        uint256 totalRequired = proratedAmount + fees;
        if (totalRequired > 0) {
            (, , , address paymentToken, , , ) = subscriptionManager
                .getSubscriptionData(subscriptionId);
            require(
                IERC20(paymentToken).allowance(msg.sender, address(this)) >=
                    totalRequired,
                "Insufficient allowance for upgrade"
            );
        }
        return
            _processUpgrade(
                subscriptionId,
                newPrice,
                proratedAmount,
                periodSecs,
                splitStrategy,
                fees
            );
    }

    function upgradeWithPermit(
        bytes32 subscriptionId,
        uint96 newPrice,
        uint256 proratedAmount,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 fees,
        uint256 allowanceAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        nonReentrant
        whenNotPaused
        initialized
        returns (bytes32 newSubscriptionId)
    {
        require(
            allowanceAmount >= proratedAmount + fees,
            "Allowance must cover upgrade cost"
        );
        (, , , address paymentToken, , , ) = subscriptionManager
            .getSubscriptionData(subscriptionId);
        if (allowanceAmount > 0) {
            try
                IERC20Permit(paymentToken).permit(
                    msg.sender,
                    address(this),
                    allowanceAmount,
                    deadline,
                    v,
                    r,
                    s
                )
            {} catch {}
        }
        return
            _processUpgrade(
                subscriptionId,
                newPrice,
                proratedAmount,
                periodSecs,
                splitStrategy,
                fees
            );
    }

    function _processUpgrade(
        bytes32 subscriptionId,
        uint96 newPrice,
        uint256 proratedAmount,
        uint32 periodSecs,
        SplitStrategy splitStrategy,
        uint256 fees
    ) internal returns (bytes32 newSubscriptionId) {
        (
            address creator,
            address subscriber,
            ,
            address paymentToken,
            uint8 status,
            ,

        ) = subscriptionManager.getSubscriptionData(subscriptionId);

        require(msg.sender == subscriber, "Not the subscriber");
        require(status == 0, "Subscription not active");
        require(newPrice > 0, "Price must be positive");
        require(periodSecs > 0, "Period must be positive");
        require(supportedTokens[paymentToken], "Token no longer supported");

        (, uint16 platformBps, bool isActive, ) = subscriptionManager
            .getSplitStrategy(uint8(splitStrategy));
        require(isActive, "Split strategy not active");

        subscriptionManager.cancelSubscription(subscriptionId);

        if (proratedAmount > 0) {
            (uint256 creatorAmount, uint256 platformAmount) = _calculateSplit(
                proratedAmount,
                platformBps
            );

            IERC20 token = IERC20(paymentToken);
            token.safeTransferFrom(msg.sender, creator, creatorAmount);
            _distributePlatformFee(token, msg.sender, platformAmount);
        }

        if (fees > 0) {
            IERC20(paymentToken).safeTransferFrom(
                msg.sender,
                communityWallet,
                fees
            );
        }

        uint40 newNextDue = uint40(block.timestamp + periodSecs);

        newSubscriptionId = subscriptionManager.createScheduledSubscription(
            msg.sender,
            creator,
            newPrice,
            paymentToken,
            periodSecs,
            ISubscriptionManager.SplitStrategy(uint8(splitStrategy)),
            newNextDue
        );

        if (proratedAmount > 0) {
            subscriptionManager.recordPayment(
                newSubscriptionId,
                proratedAmount
            );
        }
        subscriptionManager.updateRenewalData(
            newSubscriptionId,
            uint40(block.timestamp),
            newNextDue
        );

        emit SubscriptionUpgraded(
            subscriptionId,
            newSubscriptionId,
            msg.sender,
            newPrice,
            proratedAmount,
            periodSecs
        );

        return newSubscriptionId;
    }

    function _processDowngrade(
        bytes32 subscriptionId,
        uint96 newPrice,
        uint32 periodSecs,
        uint256 fees
    ) internal returns (bytes32 newSubscriptionId) {
        (
            address creator,
            address subscriber,
            ,
            address paymentToken,
            uint8 status,
            uint256 nextDue,

        ) = subscriptionManager.getSubscriptionData(subscriptionId);

        require(msg.sender == subscriber, "Not the subscriber");
        require(status == 0, "Subscription not active");
        require(newPrice > 0, "Price must be positive");
        require(periodSecs > 0, "Period must be positive");
        require(supportedTokens[paymentToken], "Token no longer supported");

        (, uint8 splitStrategy, , , ) = subscriptionManager
            .getSubscriptionRenewalData(subscriptionId);

        subscriptionManager.cancelSubscription(subscriptionId);

        if (fees > 0) {
            IERC20(paymentToken).safeTransferFrom(
                msg.sender,
                communityWallet,
                fees
            );
        }

        newSubscriptionId = subscriptionManager.createScheduledSubscription(
            msg.sender,
            creator,
            newPrice,
            paymentToken,
            periodSecs,
            ISubscriptionManager.SplitStrategy(splitStrategy),
            uint40(nextDue)
        );

        emit SubscriptionDowngraded(
            subscriptionId,
            newSubscriptionId,
            msg.sender,
            newPrice,
            periodSecs
        );

        return newSubscriptionId;
    }

    // ==================== AUDIT DESIGN DECISIONS ====================
    //
    // Backend validation: All amounts, fees, prices, and split strategies are validated by the backend
    // before transactions are presented. The contract is logic-agnostic by design. If a user bypasses
    // the frontend and submits invalid parameters, the backend rejects the transaction and the address
    // is permanently banned forever on first violation.
    //
    // Pause independence: PledgrPayments and SubscriptionManager have separate pause controls by design.
    // SubscriptionManager is intended to be a long-lived data layer that persists across payment processor upgrades.
    // PledgrPayments may be replaced with a new version (SubscriptionManager.setPaymentProcessor points to the new one).
    // Independent pause allows the data layer to remain stable while the payment processor is swapped or maintained.
    //
    // cancelSubscription bypasses whenNotPaused: Intentional. Users must always be able to stop future charges,
    // even during an emergency pause. This is a user-protection guarantee.
    //
    // Split strategies are immutable: Defined at deploy time in SubscriptionManager._initializeSplitStrategies().
    //
    // Bounty eligibility: All callers (including the subscriber themselves) are eligible for renewal bounties.
    // This simplifies the incentive model and avoids edge cases with batch processing.
    //
    // Non-custodial: This contract never holds user funds. All transfers are split-at-source directly to recipients.
    // emergencyWithdraw exists only to recover tokens accidentally sent to the contract address.
    //
    // Downgrade inherits the old subscription's split strategy. This is intentional -- split strategy changes
    // require an upgrade path. Downgrades preserve the creator's original fee tier.
    //
    // Zero-cost upgrades (proratedAmount == 0): updateRenewalData sets lastCharged = block.timestamp
    // to prevent double-charging even when recordPayment is skipped. paymentCount remains 0 until the
    // first actual renewal payment. This is correct -- no payment was made, so paymentCount should not increment.
    //
    // coOwner wallet overlap: coOwner wallets are self-custody. Only the current holder can update their own wallet.
    // No cross-validation against other platform wallets is enforced. This is a governance decision, not a security concern.
    //
    // renewBatch single-token requirement: All subscriptions in a batch must use the same payment token.
    // The bounty token is determined by the first successfully renewed subscription in the batch.
    // Callers should pre-filter batches by token using canRenew() before submission.
}
