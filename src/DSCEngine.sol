//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author V.Bezak
 * The system is designed to be as minimal as possible, and heave the tokens maintan a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algorithmically stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all DSC be less than collateral.
 *
 * @notice This contract is the core of the DSC system. It handles all logic for mining and redeeming DSC,
 * as well as depositin & withdrawal of collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    //////////////////////////
    // Errors
    //////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();

    //////////////////////////
    // State variables
    //////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant DECIMALS = 18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Means you have to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256) tokens) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////
    // Events
    //////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

    //////////////////////////
    // Modifiers
    //////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedCollateralToken(address token) {
        if (s_priceFeeds[token] == address(0x0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    //////////////////////////
    // Functions
    //////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD price feeds

        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////
    // External Functions
    //////////////////////////
    function depositCollateralAndMintDsc(uint256 _collateralAmount) external {}

    /**
     * @notice Follows CEI - Checks Effects Interactions pattern
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedCollateralToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc(uint256 _dscAmount) external {}

    function redeemCollateral() external {}

    /**
     * @notice Follows CEI - Checks Effects Interactions pattern
     * @param _amountDscToMint - The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than minimal threshold
     */

    // Check if the collateral value > DSC amount
    function mintDsc(uint256 _amountDscToMint) external moreThanZero(_amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += _amountDscToMint;

        // if they minted too much ($150 DSC, $100 ETH )
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);

        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    // There will be threshould, let;s say 150%
    // $100 ETH collateral, $50 DSC minted
    // Price of ETH tanks to $74
    // If someone pays back your minted DSC, they can have all your collateral for a discount
    // Person pays $50 DSC and gets $74 worth of ETH - and he makes $24 profits

    function liquidate() external {}

    function getHealthFactor() external view {}

    //////////////////////////
    // Private and Internal Functions
    //////////////////////////
    /**
     * Returns how close to liquidation a user is
     * If user goes bellow 1, then they can get liquidated
     */
    function _healthFactor(address _user) internal view returns (uint256 healthFactor) {
        //Total DSC minted
        //Total collateral value
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(_user);
        uint256 collateralAdjustedForThreshold = (totalCollateralValueInUsd * LIQUIDATION_PRECISION) / 100;
        healthFactor = (collateralAdjustedForThreshold * LIQUIDATION_PRECISION) / totalDscMinted;
        return healthFactor;
    }

    function _getAccountInformation(address _user)
        internal
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[_user];
        totalCollateralValueInUsd = getAccountCollateralValueInUsd(_user);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1. Check factor - do they have enough collateral ?
        //2. Revert if they not
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////
    // Public and External View Functions
    //////////////////////////
    function getAccountCollateralValueInUsd(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through all the collateral tokens
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUsd += getValueInUsd(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getValueInUsd(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000 USD
        // The returned value from CL will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION * _amount) / DECIMALS);
    }
}
