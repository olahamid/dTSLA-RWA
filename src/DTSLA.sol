//SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ConfirmedOwner} from "../lib/chainlink-brownie-contracts/contracts/src/v0.8/ConfirmedOwner.sol";
import {Pausable} from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {FunctionsClient} from
    "../lib/chainlink-brownie-contracts/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from
    "../lib/chainlink-brownie-contracts/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";
// v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {OracleLib, AggregatorV3Interface} from "./library/OracleLib.sol";
import {Strings} from "../lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import{IDTSLA} from "../src/Interface/IDTSLA.sol";

/**
 * @title dTSLA
 * @author Ola Hamid
 * @notice This is a portfolia project, A tokenised contract to make requests to the Alpaca API to mint TSLA(TESLA)-backed dTSLA tokens
 * @dev This contract is meant to be for educational purposes only
 */
contract dTSLA is ConfirmedOwner, Pausable, FunctionsClient, ERC20, IDTSLA {
    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;
    using Strings for uint256;

    enum MintOrRedeem {
        mint,
        redeem
    }

    struct dTSLARequest {
        uint256 amountToMint;
        address requester;
        MintOrRedeem mintOrRedeem;
    }

    error dTSLA__NotEnoughCollateral();
    error dTSLA__ExceedMinAmount(uint256 min_amount);
    error dTSLA__inSufficientFund(uint amount);

    address constant Sapolia_Function_Router = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    uint32 constant Gas_Limit = 500_000;
    string private s_MintSourceCode;
    string private s_RedeemSourceCode;
    uint256 private s_portfolioBalance;
    uint64 immutable i_subId;
    uint256 private immutable i_redemptionCoinDecimals;
    bytes32 constant i_donId = hex"66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000";

    //Math Constant
    uint256 constant PRECISION = 1e18;
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 constant COLLATERAL_RATIO = 200; //what this means is that it need a 200% percentage, if there is $200 dollar in the brokaraage. you can mint $100 dTSLA
    uint256 constant COLLATERAL_RATIO_PRECISION = 100;
    uint256 constant MINIMUM_WITHDRAW_AMOUNT = 100e18;

    address public i_tslaUsdFeed;
    address public i_usdcUsdFeed;
    /// @notice this is a redenmption coin that is selected to be the token that redeming dTSLA
    address public s_redemptionCoin;

    mapping(bytes32 requestId => dTSLARequest request) private requestIdToRequest;
    mapping (address requester => uint256 amountToRedeem ) private m_userToWithdrawAmount;

    constructor(
        address Owner,
        string memory mintSourceCode,
        string memory redeemSourceCode,
        uint64 subId,
        address _i_tslaUsdFeed,
        address _i_usdcUsdFeed,
        address _redemptionCoin
    ) ConfirmedOwner(Owner) FunctionsClient(Sapolia_Function_Router) ERC20("dTSLA", "dTSLA") {
        mintSourceCode = s_MintSourceCode;
        i_subId = subId;
        i_tslaUsdFeed = _i_tslaUsdFeed;
        i_usdcUsdFeed = _i_usdcUsdFeed;
        s_RedeemSourceCode = redeemSourceCode;
        s_redemptionCoin = _redemptionCoin;
        i_redemptionCoinDecimals = ERC20(_redemptionCoin).decimals();
    }

    /// send HTTP request to:JMKMJJ
    /// 1. see much TSLA was bought
    /// 2. if TSLA is in alpaca Account, then mint dTSLA
    /// 2 trasaction function, this is a request ans receive function, ehat this does is that it check th alpaca account and see if there is enough TSLA stock in there, it there it tells the contract that hey contract you can mint dTSLA, there is eneogh money in alpaca
    function sendMintRequest(uint256 amount) external onlyOwner returns (bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_MintSourceCode);
        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, Gas_Limit, i_donId);
        requestIdToRequest[requestId] = dTSLARequest(amount, msg.sender, MintOrRedeem.mint);
        return requestId;
    }
    //returns the amount of TSLA value in USD is bought and stored in our brokerage
    //if we have enough tsla token mint dTSLA

    /// @notice User will send request to sell TSLA for USDC.abi
    /// This will have a chainlink function call the alpaca:
    // sell TSLA on the brokerage
    // Buy USDC on the brokerage
    // send USDC to this contract for the user to withdraw

    function sendRedeemRequest(uint256 amountdTSLA) external onlyOwner {
        //create a min redemtion amount, why because we are using alpaca and it uses it has a min amount that can be bought back just like some other brokarage.
        uint256 amountTSLAInUSDC = getUSDCValueOfUSD(getUSDValueOfTSLA(amountdTSLA));
        if (amountTSLAInUSDC > MINIMUM_WITHDRAW_AMOUNT) {
            revert dTSLA__ExceedMinAmount(MINIMUM_WITHDRAW_AMOUNT);
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_RedeemSourceCode); // Initialize the request with JS code

        string[] memory args = new string [](2);
        args[0] = amountdTSLA.toString(); //sell this much TSLA
        args[1] = amountTSLAInUSDC.toString(); // send this much USDC back to the contract 
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, Gas_Limit, i_donId);
        requestIdToRequest[requestId] = dTSLARequest(amountdTSLA, msg.sender, MintOrRedeem.redeem);
        // so we are going to burn, 
        _burn(msg.sender, amountdTSLA);
    }
    function _redeemFulfilRequest(bytes32 requestId, bytes memory response) internal {
        uint amountUSDC = uint256(bytes32(response));
        uint usdcAmountWad;
        if (i_redemptionCoinDecimals < 18) {
            usdcAmountWad = amountUSDC * (10 ** (18 - i_redemptionCoinDecimals));

        }
        // if our API from alpaca returns zero then, you can mint back the amount backed to the user ie a refund
        if (amountUSDC == 0) {
            uint256 amountOfdTSLABurned = requestIdToRequest[requestId].amountToMint;
            _mint(requestIdToRequest[requestId].requester, amountOfdTSLABurned);
            return;
        }
        m_userToWithdrawAmount[requestIdToRequest[requestId].requester] += amountUSDC;
    }
    function withdraw() external {
        uint redeemWithdrawAmount = m_userToWithdrawAmount[msg.sender];
        m_userToWithdrawAmount[msg.sender] = 0;

        bool success = ERC20(s_redemptionCoin).transfer(msg.sender, redeemWithdrawAmount);
        if (!success) {
            revert dTSLA__inSufficientFund(redeemWithdrawAmount);
        }
         
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/



    function _mintFulfilRequest(bytes32 requestId, bytes memory response) internal {
        uint256 amountOfTokenToMint = requestIdToRequest[requestId].amountToMint;
        s_portfolioBalance = uint256(bytes32(response));

        //if the tsla collateral value(AKA how much tsla weve bought) is greater than the amount dTSLA then we mint
        // how much DTSLA in $$do we have?
        //how much DTSLA in $$$ are we minting?

        //what the if statement below is saying is that we should rather have a more total token in stock than we have in dTSLA in token
        if (_collateralRatioAdjustedTotalBalance(amountOfTokenToMint) > s_portfolioBalance) {
            revert dTSLA__NotEnoughCollateral();
        }
        if (amountOfTokenToMint != 0) {
            _mint(requestIdToRequest[requestId].requester, amountOfTokenToMint);
        }
    }

    function _collateralRatioAdjustedTotalBalance(uint256 amountTokenToMint) internal view returns (uint256) {
        uint256 calculateNewTotalValue = getCalculatedNewTotalValue(amountTokenToMint);
        return calculateNewTotalValue;
    }
    //the new expected total value in USD of all the dTSLA tokens combined

    function getCalculatedNewTotalValue(uint256 amountTokenToMint) internal view returns (uint256) {
        //the line below says that if the current addr has totaldTSLA of 10 + extra of 5 ) x pricetoUSD / precision(cause of math in solidity)
        uint256 calculatedValue = ((totalSupply() + amountTokenToMint) * getTSLAPerPrice()) / PRECISION;
        ((calculatedValue * COLLATERAL_RATIO) / COLLATERAL_RATIO_PRECISION);
        return calculatedValue;
    }
    



    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /*error*/ ) internal override {
        if (requestIdToRequest[requestId].mintOrRedeem == MintOrRedeem.mint) {
            _mintFulfilRequest(requestId, response);
        } else {
            _redeemFulfilRequest(requestId, response);
        }
    }



    /*//////////////////////////////////////////////////////////////
                             VIEW AND PURE
    //////////////////////////////////////////////////////////////*/

    function getUSDCValueOfUSD(uint256 usdAmount) public view returns (uint256) {
        return (usdAmount * getUSDCPerPrice()) / PRECISION;
    }

    function getUSDValueOfTSLA(uint256 tslaAmount) public view returns (uint256) {
        return (tslaAmount * getTSLAPerPrice()) / PRECISION;
    }

    //chainliknk priceFEED
    function getTSLAPerPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(i_tslaUsdFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        uint256 stalePrice = uint256(price) * ADDITIONAL_FEED_PRECISION; // so that we have 18 decimals
        return stalePrice;
    }

    function getUSDCPerPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(i_usdcUsdFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        uint256 stalePrice = uint256(price) * ADDITIONAL_FEED_PRECISION; // so that we have 18 decimals
        return stalePrice;
    }


    function getPortfolioBalance() public view returns (uint256) {
        return s_portfolioBalance;

    }
    function getRequest(bytes32 requestId) public view returns (dTSLARequest memory) {
        return requestIdToRequest[requestId];
    }

    function getWithdrawalAmount(address user) public view returns (uint256) {
        return m_userToWithdrawAmount[user];
    }

    function getSubID() public view returns (uint64) {
        return i_subId;
    }
    function getMintSourceCode () public view returns (string memory ) {
        return s_MintSourceCode;
    }
    function getRedeemSourceCode() public view returns (string memory){
        return s_RedeemSourceCode;
    }

    function getCollateralRatio() public pure returns (uint256) {
        return COLLATERAL_RATIO;
    }
    function getCollateralPrecision () public pure returns (uint256) {
        return COLLATERAL_RATIO_PRECISION;
    }
}
 