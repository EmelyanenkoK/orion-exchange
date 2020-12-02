pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./utils/ReentrancyGuard.sol";
import "./libs/LibUnitConverter.sol";
import "./libs/LibValidator.sol";
import "./libs/MarginalFunctionality.sol";

/**
 * @title Exchange
 * @dev Exchange contract for the Orion Protocol
 * @author @wafflemakr
 */

/*

  Overflow safety:
  We do not use SafeMath and control overflows by
  not accepting large ints on input.

  Balances inside contract are stored as int192.

  Allowed input amounts are int112 or uint112: it is enough for all
  practically used tokens: for instance if decimal unit is 1e18, int112
  allow to encode up to 2.5e15 decimal units.
  That way adding/subtracting any amount from balances won't overflow, since
  minimum number of operations to reach max int is practically infinite: ~1e24.

  Allowed prices are uint64. Note, that price is represented as
  price per 1e8 tokens. That means that amount*price always fit uint256,
  while amount*price/1e8 not only fit int192, but also can be added, subtracted
  without overflow checks: number of malicion operations to overflow ~1e13.
*/
contract Exchange is ReentrancyGuard, OwnableUpgradeSafe {

    using LibValidator for LibValidator.Order;
    using SafeERC20 for IERC20;

    // EVENTS
    event NewAssetTransaction(
        address indexed user,
        address indexed assetAddress,
        bool isDeposit,
        uint112 amount,
        uint64 timestamp
    );

    event NewTrade(
        address indexed buyer,
        address indexed seller,
        address baseAsset,
        address quoteAsset,
        uint64 filledPrice,
        uint192 filledAmount,
        uint192 amountQuote
    );

    //order -> filledAmount
    mapping(bytes32 => uint192) public filledAmounts;


    // Get user balance by address and asset address
    mapping(address => mapping(address => int192)) private assetBalances;
    // List of assets with negative balance for each user
    mapping(address => MarginalFunctionality.Liability[]) public liabilities;
    // List of assets which can be used as collateral and risk coefficients for them
    address[] private collateralAssets;
    mapping(address => uint8) public assetRisks;
    // Risk coefficient for locked ORN
    uint8 public stakeRisk;
    // Liquidation premium
    uint8 public liquidationPremium;
    // Delays after which price and position become outdated
    uint64 public priceOverdue;
    uint64 public positionOverdue;

    IERC20 _orionToken;
    address _oracleAddress;
    address _allowedMatcher;

    // MAIN FUNCTIONS

    function initialize() public payable initializer {
        OwnableUpgradeSafe.__Ownable_init();
    }

    function setBasicParams(address orionVaultContractAddress, address orionToken, address priceOracleAddress, address allowedMatcher) public onlyOwner {
      _orionToken = IERC20(orionToken);
      _oracleAddress = priceOracleAddress;
      _allowedMatcher = allowedMatcher;
    }

    function updateMarginalSettings(address[] memory _collateralAssets,
                                    uint8 _stakeRisk,
                                    uint8 _liquidationPremium,
                                    uint64 _priceOverdue,
                                    uint64 _positionOverdue) public onlyOwner {
      collateralAssets = _collateralAssets;
      stakeRisk = _stakeRisk;
      liquidationPremium = _liquidationPremium;
      priceOverdue = _priceOverdue;
      positionOverdue = _positionOverdue;
    }

    function updateAssetRisks(address[] memory assets, uint8[] memory risks) public onlyOwner {
        for(uint16 i; i< assets.length; i++)
         assetRisks[assets[i]] = risks[i];
    }

    /**
     * @dev Deposit ERC20 tokens to the exchange contract
     * @dev User needs to approve token contract first
     * @param amount asset amount to deposit in its base unit
     */
    function depositAsset(address assetAddress, uint112 amount) external {
        //require(asset.transferFrom(msg.sender, address(this), uint256(amount)), "E6");
        IERC20(assetAddress).safeTransferFrom(msg.sender, address(this), uint256(amount));
        generalDeposit(assetAddress,amount);
    }

    /**
     * @notice Deposit ETH to the exchange contract
     * @dev deposit event will be emitted with the amount in decimal format (10^8)
     * @dev balance will be stored in decimal format too
     */
    function deposit() external payable {
        generalDeposit(address(0), uint112(msg.value));
    }

    function generalDeposit(address assetAddress, uint112 amount) internal {
        address user = msg.sender;
        bool wasLiability = assetBalances[user][assetAddress]<0;
        int112 safeAmountDecimal = LibUnitConverter.baseUnitToDecimal(
            assetAddress,
            amount
        );
        assetBalances[user][assetAddress] += safeAmountDecimal;
        if(amount>0)
          emit NewAssetTransaction(user, assetAddress, true, uint112(safeAmountDecimal), uint64(now));
        if(wasLiability)
          MarginalFunctionality.updateLiability(user, assetAddress, liabilities, uint112(safeAmountDecimal), assetBalances[user][assetAddress]);

    }
    /**
     * @dev Withdrawal of remaining funds from the contract back to the address
     * @param assetAddress address of the asset to withdraw
     * @param amount asset amount to withdraw in its base unit
     */
    function withdraw(address assetAddress, uint112 amount)
        external
        nonReentrant
    {
        int112 safeAmountDecimal = LibUnitConverter.baseUnitToDecimal(
            assetAddress,
            amount
        );

        address user = msg.sender;

        require(assetBalances[user][assetAddress]>=safeAmountDecimal && checkPosition(user), "E1w"); //TODO
        assetBalances[user][assetAddress] -= safeAmountDecimal;
        
        uint256 _amount = uint256(amount);
        if(assetAddress == address(0)) {
          (bool success, ) = user.call.value(_amount)("");
          require(success, "E6w");
        } else {
          IERC20(assetAddress).safeTransfer(user, _amount);
        }


        emit NewAssetTransaction(user, assetAddress, false, uint112(safeAmountDecimal), uint64(now));
    }


    /**
     * @dev Get asset balance for a specific address
     * @param assetAddress address of the asset to query
     * @param user user address to query
     */
    function getBalance(address assetAddress, address user)
        public
        view
        returns (int192 assetBalance)
    {
        return assetBalances[user][assetAddress];
    }


    /**
     * @dev Batch query of asset balances for a user
     * @param assetsAddresses array of addresses of teh assets to query
     * @param user user address to query
     */
    function getBalances(address[] memory assetsAddresses, address user)
        public
        view
        returns (int192[] memory)
    {
        int192[] memory balances = new int192[](assetsAddresses.length);
        for (uint16 i; i < assetsAddresses.length; i++) {
            balances[i] = assetBalances[user][assetsAddresses[i]];
        }
        return balances;
    }

    function getLiabilities(address user)
        public
        view
        returns (MarginalFunctionality.Liability[] memory liabilitiesArray)
    {
        return liabilities[user];
    }
    

    function getCollateralAssets() public view returns (address[] memory) {
        return collateralAssets;
    }

    /**
     * @dev get hash for an order
     */
    function getOrderHash(LibValidator.Order memory order) public pure returns (bytes32){
      return order.getTypeValueHash();
    }


    /**
     * @dev get trades for a specific order
     */
    function getFilledAmounts(bytes32 orderHash, LibValidator.Order memory order)
        public
        view
        returns (int192 totalFilled, int192 totalFeesPaid)
    {
        totalFilled = int192(filledAmounts[orderHash]); //It is safe to convert here: filledAmounts is result of ui112 additions
        totalFeesPaid = int192(uint256(order.matcherFee)*uint112(totalFilled)/order.amount); //matcherFee is u64; safe multiplication here
    }


    /**
     * @notice Settle a trade with two orders, filled price and amount
     * @dev 2 orders are submitted, it is necessary to match them:
        check conditions in orders for compliance filledPrice, filledAmountbuyOrderHash
        change balances on the contract respectively with buyer, seller, matcbuyOrderHashher
     * @param buyOrder structure of buy side orderbuyOrderHash
     * @param sellOrder structure of sell side order
     * @param filledPrice price at which the order was settled
     * @param filledAmount amount settled between orders
     */
    function fillOrders(
        LibValidator.Order memory buyOrder,
        LibValidator.Order memory sellOrder,
        uint64 filledPrice,
        uint112 filledAmount
    ) public nonReentrant {
        // --- VARIABLES --- //
        // Amount of quote asset
        uint256 _amountQuote = uint256(filledAmount)*filledPrice/(10**8);
        require(_amountQuote<2**112-1, "E12G");
        uint112 amountQuote = uint112(_amountQuote);

        // Order Hashes
        bytes32 buyOrderHash = buyOrder.getTypeValueHash();
        bytes32 sellOrderHash = sellOrder.getTypeValueHash();

        // --- VALIDATIONS --- //

        // Validate signatures using eth typed sign V1
        require(
            LibValidator.checkOrdersInfo(
                buyOrder,
                sellOrder,
                msg.sender,
                filledAmount,
                filledPrice,
                now,
                _allowedMatcher
            ),
            "E3G"
        );


        // --- UPDATES --- //

        //updateFilledAmount
        filledAmounts[buyOrderHash] += filledAmount; //it is safe to add ui112 to each other to get i192
        filledAmounts[sellOrderHash] += filledAmount;
        require(filledAmounts[buyOrderHash] <= buyOrder.amount, "E12B");
        require(filledAmounts[sellOrderHash] <= sellOrder.amount, "E12S");


        // Update User's balances
        updateOrderBalance(buyOrder, filledAmount, amountQuote, true);
        updateOrderBalance(sellOrder, filledAmount, amountQuote, false);
        require(checkPosition(buyOrder.senderAddress), "Incorrect margin position for buyer");
        require(checkPosition(sellOrder.senderAddress), "Incorrect margin position for seller");


        emit NewTrade(
            buyOrder.senderAddress,
            sellOrder.senderAddress,
            buyOrder.baseAsset,
            buyOrder.quoteAsset,
            filledPrice,
            filledAmount,
            amountQuote
        );
    }

    function validateOrder(LibValidator.Order memory order)
        public
        pure
        returns (bool isValid)
    {
        isValid = LibValidator.validateV3(order);
    }

    /**
     *  @notice update user balances and send matcher fee
     *  @param isBuyer boolean, indicating true if the update is for buyer, false for seller
     */
    function updateOrderBalance(
        LibValidator.Order memory order,
        uint112 filledAmount,
        uint112 amountQuote,
        bool isBuyer
    ) internal {
        address user = order.senderAddress;

        // matcherFee: u64, filledAmount u128 => matcherFee*filledAmount fit u256
        // result matcherFee fit u64
        order.matcherFee = uint64(uint256(order.matcherFee)*filledAmount/order.amount); //rewrite in memory only
        if(!isBuyer)
          (filledAmount, amountQuote) = (amountQuote, filledAmount);

        bool feeAssetInLiabilities  = assetBalances[user][order.matcherFeeAsset]<0;
        (address firstAsset, address secondAsset) = isBuyer?
                                                     (order.quoteAsset, order.baseAsset):
                                                     (order.baseAsset, order.quoteAsset);
        int192 firstBalance = assetBalances[user][firstAsset];
        int192 secondBalance = assetBalances[user][secondAsset];
        int192 temp; // this variable will be used for temporary variable storage (optimization purpose)
        bool firstInLiabilities = firstBalance<0;
        bool secondInLiabilities  = secondBalance<0;

        temp = assetBalances[user][firstAsset] - amountQuote;
        assetBalances[user][firstAsset] = temp;
        assetBalances[user][secondAsset] += filledAmount;
        if(!firstInLiabilities && (temp<0)){
          setLiability(user, firstAsset, temp);
        }
        if(secondInLiabilities && (assetBalances[user][secondAsset]>=0)) {
          MarginalFunctionality.removeLiability(user, secondAsset, liabilities);
        }

        // User pay for fees
        temp = assetBalances[user][order.matcherFeeAsset] - order.matcherFee;
        assetBalances[user][order.matcherFeeAsset] = temp;
        if(!feeAssetInLiabilities && (temp<0)) {
            setLiability(user, order.matcherFeeAsset, temp);
        }
        assetBalances[order.matcherAddress][order.matcherFeeAsset] += order.matcherFee;
        //generalTransfer(order.matcherFeeAsset, order.matcherAddress, order.matcherFee, true);
        //IERC20(order.matcherFeeAsset).safeTransfer(order.matcherAddress, uint256(order.matcherFee)); //TODO not transfer, but add to balance
    }

    /**
     * @notice users can cancel an order
     * @dev write an orderHash in the contract so that such an order cannot be filled (executed)
     */
    /* Unused for now
    function cancelOrder(LibValidator.Order memory order) public {
        require(order.validateV3(), "E2");
        require(msg.sender == order.senderAddress, "Not owner");

        bytes32 orderHash = order.getTypeValueHash();

        require(!isOrderCancelled(orderHash), "E4");

        (
            int192 totalFilled, //uint totalFeesPaid

        ) = getFilledAmounts(orderHash);

        if (totalFilled > 0)
            orderStatus[orderHash] = Status.PARTIALLY_CANCELLED;
        else orderStatus[orderHash] = Status.CANCELLED;

        emit OrderUpdate(orderHash, msg.sender, orderStatus[orderHash]);

        assert(
            orderStatus[orderHash] == Status.PARTIALLY_CANCELLED ||
                orderStatus[orderHash] == Status.CANCELLED
        );
    }
    */

    function checkPosition(address user) public view returns (bool) {
        if(liabilities[user].length == 0)
          return true;
        return calcPosition(user).state == MarginalFunctionality.PositionState.POSITIVE;
    }

    function getConstants(address user)
             internal
             view
             returns (MarginalFunctionality.UsedConstants memory) {
       return MarginalFunctionality.UsedConstants(user,
                                                  _oracleAddress,
                                                  address(this),
                                                  address(_orionToken),
                                                  positionOverdue,
                                                  priceOverdue,
                                                  stakeRisk,
                                                  liquidationPremium);
    }

    function calcPosition(address user) public view returns (MarginalFunctionality.Position memory) {
        MarginalFunctionality.UsedConstants memory constants =
          getConstants(user);
        return MarginalFunctionality.calcPosition(collateralAssets,
                                           liabilities,
                                           assetBalances,
                                           assetRisks,
                                           constants);

    }

    function partiallyLiquidate(address broker, address redeemedAsset, uint112 amount) public {
        MarginalFunctionality.UsedConstants memory constants =
          getConstants(broker);
        MarginalFunctionality.partiallyLiquidate(collateralAssets,
                                           liabilities,
                                           assetBalances,
                                           assetRisks,
                                           constants,
                                           redeemedAsset,
                                           amount);
    }

    function setLiability(address user, address asset, int192 balance) internal {
        liabilities[user].push(
          MarginalFunctionality.Liability({
                                             asset: asset,
                                             timestamp: uint64(now),
                                             outstandingAmount: uint192(-balance)})
        );
    }

    /**
     *  @dev  revert on fallback function
     */
    fallback() external {
        revert("E6");
    }

    /* Error Codes

        E1: Insufficient Balance,
        E2: Invalid Signature,
        E3: Invalid Order Info,
        E4: Order cancelled or expired,
        E5: Contract not active,
        E6: Transfer error
        E7: Incorrect state prior to liquidation
        E8: Liquidator doesn't satisfy requirements
        E9: Data for liquidation handling is outdated
        E10: Incorrect state after liquidation
        E11: Amount overflow
    */

// OrionVault part, will be moved in right place after successfull tests

    enum StakePhase{ NOTSTAKED, LOCKING, LOCKED, RELEASING, READYTORELEASE, FROZEN }

    struct Stake {
      uint64 amount; // 100m ORN in circulation fits uint64
      StakePhase phase;
      uint64 lastActionTimestamp;
    }

    uint64 constant releasingDuration = 3600*24;
    mapping(address => Stake) private stakingData;



    function getStake(address user) public view returns (Stake memory){
        Stake memory stake = stakingData[user];
        if(stake.phase == StakePhase.LOCKING && (now - stake.lastActionTimestamp) > 0) {
          stake.phase = StakePhase.LOCKED;
        } else if(stake.phase == StakePhase.RELEASING && (now - stake.lastActionTimestamp) > releasingDuration) {
          stake.phase = StakePhase.READYTORELEASE;
        }
        return stake;
    }

    function getStakeBalance(address user) public view returns (uint256) {
        return getStake(user).amount;
    }

    function getStakePhase(address user) public view returns (StakePhase) {
        return getStake(user).phase;
    }

    function getLockedStakeBalance(address user) public view returns (uint256) {
      Stake memory stake = getStake(user);
      if(stake.phase == StakePhase.LOCKED || stake.phase == StakePhase.FROZEN)
        return stake.amount;
      return 0;
    }



    function postponeStakeRelease(address user) external onlyOwner{
        Stake storage stake = stakingData[user];
        stake.phase = StakePhase.FROZEN;
    }

    function allowStakeRelease(address user) external onlyOwner {
        Stake storage stake = stakingData[user];
        stake.phase = StakePhase.READYTORELEASE;
    }



    function requestReleaseStake() public {
        address user = _msgSender();
        Stake memory current = getStake(user);
        require(liabilities[user].length == 0, "Can not release stake: user has liabilities");
        if(current.phase == StakePhase.LOCKING || current.phase == StakePhase.READYTORELEASE) {
          Stake storage stake = stakingData[_msgSender()];
          assetBalances[user][address(_orionToken)] += stake.amount;
          stake.amount = 0;
          stake.phase = StakePhase.NOTSTAKED;
        } else if (current.phase == StakePhase.LOCKED) {
          Stake storage stake = stakingData[_msgSender()];
          stake.phase = StakePhase.RELEASING;
          stake.lastActionTimestamp = uint64(now);
        } else {
          revert("Can not release funds from this phase");
        }
    }

    function lockStake(uint64 amount) public {
        address user = _msgSender();
        require(assetBalances[user][address(_orionToken)]>amount, "E1S");
        Stake storage stake = stakingData[user];

        assetBalances[user][address(_orionToken)] -= amount;
        stake.amount = amount;
        
        if(stake.phase != StakePhase.FROZEN) {
          stake.phase = StakePhase.LOCKING; //what is frozen should stay frozen
        }
        stake.lastActionTimestamp = uint64(now);
    }

    function seizeFromStake(address user, address receiver, uint64 amount) public {
        require(msg.sender == address(this), "E14");
        Stake storage stake = stakingData[user];
        require(stake.amount >= amount, "UX"); //TODO
        stake.amount -= amount;
        assetBalances[receiver][address(_orionToken)] += amount;
    }


}
