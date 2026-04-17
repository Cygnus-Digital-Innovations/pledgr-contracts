// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./BuyOutAuction.sol";

contract BuyOutAuctionFactory is Ownable {
    using Address for address;

    uint16 public constant CO_OWNER1_BPS = 4000;
    uint16 public constant CO_OWNER2_BPS = 4000;
    uint16 public constant COMMUNITY_BPS = 2000;

    address public coOwner1Wallet;
    address public coOwner2Wallet;
    address public communityWallet;

    address public immutable USDC;
    address public immutable USDT;

    uint256 public auctionCount;

    mapping(uint256 => address) public auctions;
    mapping(address => address) public auctionPaymentToken;
    mapping(address => address[]) public ownerAuctions;

    struct SplitConfig {
        uint16 creatorBps;
        uint16 platformBps;
        bool isActive;
    }

    mapping(uint8 => SplitConfig) public splitStrategies;

    enum PaymentToken { USDC_TOKEN, USDT_TOKEN }

    struct AuctionParams {
        PaymentToken paymentToken;
        uint256 startingPrice;
        uint256 buyOutPrice;
        uint256 tickSize;
        uint256 startTime;
        uint256 endTime;
        bool buyOutEnabled;
        uint8 splitStrategy;
    }

    event AuctionCreated(
        address indexed auction,
        address indexed owner,
        address paymentToken,
        uint256 startingPrice,
        uint256 buyOutPrice,
        uint256 tickSize,
        uint256 startTime,
        uint256 endTime,
        bool buyOutEnabled,
        uint8 splitStrategy
    );

    event CoOwner1WalletUpdated(address indexed oldWallet, address indexed newWallet);
    event CoOwner2WalletUpdated(address indexed oldWallet, address indexed newWallet);
    event CommunityWalletUpdated(address indexed oldWallet, address indexed newWallet);

    constructor(
        address _usdc,
        address _usdt,
        address _coOwner1Wallet,
        address _coOwner2Wallet,
        address _communityWallet
    ) {
        require(_usdc != address(0), "Invalid USDC");
        require(_usdt != address(0), "Invalid USDT");
        require(_coOwner1Wallet != address(0), "Invalid coOwner1");
        require(_coOwner2Wallet != address(0), "Invalid coOwner2");
        require(_communityWallet != address(0), "Invalid community");

        USDC = _usdc;
        USDT = _usdt;
        coOwner1Wallet = _coOwner1Wallet;
        coOwner2Wallet = _coOwner2Wallet;
        communityWallet = _communityWallet;

        splitStrategies[0] = SplitConfig(10000, 0, true);
        splitStrategies[1] = SplitConfig(9600, 400, true);
        splitStrategies[2] = SplitConfig(9500, 500, true);
        splitStrategies[3] = SplitConfig(9400, 600, true);
        splitStrategies[4] = SplitConfig(9300, 700, true);
        splitStrategies[5] = SplitConfig(9000, 1000, true);
    }

    function _resolveToken(PaymentToken _token) internal view returns (address) {
        if (_token == PaymentToken.USDC_TOKEN) return USDC;
        return USDT;
    }

    function createAuction(AuctionParams calldata params) external returns (address) {
        address tokenAddr = _resolveToken(params.paymentToken);
        SplitConfig memory config = splitStrategies[params.splitStrategy];
        require(config.isActive, "Invalid split strategy");

        BuyOutAuction auction = new BuyOutAuction(
            tokenAddr,
            coOwner1Wallet,
            coOwner2Wallet,
            communityWallet,
            config.creatorBps,
            config.platformBps
        );

        auction.initialize(
            msg.sender,
            params.startingPrice,
            params.buyOutPrice,
            params.tickSize,
            params.startTime,
            params.endTime,
            params.buyOutEnabled
        );

        address auctionAddr = address(auction);
        auctions[auctionCount] = auctionAddr;
        auctionPaymentToken[auctionAddr] = tokenAddr;
        ownerAuctions[msg.sender].push(auctionAddr);
        auctionCount++;

        emit AuctionCreated(
            auctionAddr,
            msg.sender,
            tokenAddr,
            params.startingPrice,
            params.buyOutPrice,
            params.tickSize,
            params.startTime,
            params.endTime,
            params.buyOutEnabled,
            params.splitStrategy
        );

        return auctionAddr;
    }

    function getAuctionsByOwner(address _owner) external view returns (address[] memory) {
        return ownerAuctions[_owner];
    }

    function getAuctionCount() external view returns (uint256) {
        return auctionCount;
    }

    function getSplitStrategy(uint8 _strategy) external view returns (uint16 creatorBps, uint16 platformBps, bool isActive) {
        SplitConfig memory config = splitStrategies[_strategy];
        return (config.creatorBps, config.platformBps, config.isActive);
    }

    function updateCoOwner1Wallet(address _newWallet) external {
        require(msg.sender == coOwner1Wallet, "Only coOwner1");
        require(_newWallet != address(0), "Invalid address");
        address old = coOwner1Wallet;
        coOwner1Wallet = _newWallet;
        emit CoOwner1WalletUpdated(old, _newWallet);
    }

    function updateCoOwner2Wallet(address _newWallet) external {
        require(msg.sender == coOwner2Wallet, "Only coOwner2");
        require(_newWallet != address(0), "Invalid address");
        address old = coOwner2Wallet;
        coOwner2Wallet = _newWallet;
        emit CoOwner2WalletUpdated(old, _newWallet);
    }

    function updateCommunityWallet(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "Invalid address");
        address old = communityWallet;
        communityWallet = _newWallet;
        emit CommunityWalletUpdated(old, _newWallet);
    }
}
