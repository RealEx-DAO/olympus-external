// ███████╗░█████╗░██████╗░██████╗░███████╗██████╗░░░░███████╗██╗
// ╚════██║██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗░░░██╔════╝██║
// ░░███╔═╝███████║██████╔╝██████╔╝█████╗░░██████╔╝░░░█████╗░░██║
// ██╔══╝░░██╔══██║██╔═══╝░██╔═══╝░██╔══╝░░██╔══██╗░░░██╔══╝░░██║
// ███████╗██║░░██║██║░░░░░██║░░░░░███████╗██║░░██║██╗██║░░░░░██║
// ╚══════╝╚═╝░░╚═╝╚═╝░░░░░╚═╝░░░░░╚══════╝╚═╝░░╚═╝╚═╝╚═╝░░░░░╚═╝
// Copyright (C) 2021 zapper

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//

/// @author Zapper and OlympusDAO
/// @notice This contract enters/exits OlympusDAO Ω with/to any token.
/// Bonds can also be created on behalf of msg.sender using any input token.

// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import "./interfaces/IBondDepository.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/IwsOHM.sol";

import "./libraries/SafeERC20.sol";
import "./libraries/ZapBaseV2_2.sol";

contract OlympusZap is ZapBaseV2_2 {

    using SafeERC20 for IERC20;


    /////////////// storage ///////////////

    address public staking = 0xFd31c7d00Ca47653c6Ce64Af53c1571f9C36566a;

    address public constant OHM = 0x383518188C0C6d7730D91b2c03a03C837814a899;

    address public sOHM = 0x04F2694C8fcee23e8Fd0dfEA1d4f5Bb8c352111F;

    address public wsOHM = 0xCa76543Cf381ebBB277bE79574059e32108e3E65;

    // IE DAI => wanted payout token (IE OHM) => bond depo
    mapping( address => mapping( address => address ) ) public principalToDepository;

    /////////////// Events ///////////////

    // Emitted when `sender` Zaps In
    event zapIn(address sender, address token, uint256 tokensRec, address affiliate);

    // Emitted when `sender` Zaps Out
    event zapOut(address sender, address token, uint256 tokensRec, address affiliate);


    /////////////// Modifiers ///////////////

    modifier onlyOlympusDAO {
        require (msg.sender == olympusDAO);
        _;
    }

    /////////////// Construction ///////////////

    constructor(
        uint256 _goodwill, 
        uint256 _affiliateSplit
        address _olympusDAO
    ) ZapBaseV2_2(_goodwill, _affiliateSplit) {
        // 0x Proxy
        approvedTargets[ 0xDef1C0ded9bec7F1a1670819833240f027b25EfF ] = true;
        // Zapper Sushiswap Zap In
        approvedTargets[ 0x5abfbE56553a5d794330EACCF556Ca1d2a55647C ] = true;
        // Zapper Uniswap V2 Zap In
        approvedTargets[ 0x6D9893fa101CD2b1F8D1A12DE3189ff7b80FdC10 ] = true;
        
        olympusDAO = _olympusDAO;
        
        transferOwnership( ZapperAdmin );
    }

    /**
     * @notice This function deposits assets into OlympusDAO with ETH or ERC20 tokens
     * @param fromToken The token used for entry (address(0) if ether)
     * @param amountIn The amount of fromToken to invest
     * @param toToken The token fromToken is getting converted to.
     * @param minToToken The minimum acceptable quantity olympusZapManager.sOHM() 
     * or olympusZapManager.wsOHM() or principal tokens to receive. Reverts otherwise
     * @param swapTarget Excecution target for the swap or zap
     * @param swapData DEX or Zap data. Must swap to ibToken underlying address
     * @param affiliate Affiliate address
     * @param maxBondPrice Max price for a bond denominated in toToken/principal. Ignored if not bonding.
     * @param bond if toToken is being used to purchase a bond.
     * @return OHMRec quantity of sOHM or wsOHM  received (depending on toToken)
     * or the quantity OHM vesting (if bond is true)
     */
    function ZapIn(
        address fromToken,
        uint256 amountIn,
        address toToken,
        uint256 minToToken,
        address swapTarget,
        bytes calldata swapData,
        address affiliate,
        address bondPayoutToken, // ignored if not bonding
        uint maxBondPrice,       // ignored if not bonding
        bool bond
    ) external payable stopInEmergency returns ( uint OHMRec ) {
        if ( bond ) {
            // pull users fromToken
            uint256 toInvest = _pullTokens(fromToken, amountIn, affiliate, true);
            // swap fromToken -> toToken 
            uint256 tokensBought = _fillQuote(fromToken, toToken, toInvest, swapTarget, swapData);
            require(tokensBought >= minToToken, "High Slippage");
            // get depo address
            address depo = IBondDepository( principalToDepository[ toToken ][ bondPayoutToken ] );
            // deposit bond on behalf of user, and return OHMRec
            OHMRec = IBondDepository( depo ).deposit( msg.sender, toToken, tokensBought, maxBondPrice );
            // emit zapIn
            emit zapIn(msg.sender, toToken, OHMRec, affiliate);
        } else {
            require(toToken == olympusZapManager.sOHM() || toToken == olympusZapManager.wsOHM(), "toToken must be sOHM or wsOHM");
            uint256 toInvest = _pullTokens(fromToken, amountIn, affiliate, true);
            uint256 tokensBought = _fillQuote(fromToken, olympusZapManager.OHM(), toInvest, swapTarget, swapData);
            OHMRec = _enterOlympus(tokensBought, toToken);
            require(OHMRec > minToToken, "High Slippage");
            emit zapIn(msg.sender, olympusZapManager.sOHM() , OHMRec, affiliate);
        }
    }

    /**
     * @notice This function withdraws assets from OlympusDAO, receiving tokens or ETH
     * @param fromToken The ibToken being withdrawn
     * @param amountIn The quantity of fromToken to withdraw
     * @param toToken Address of the token to receive (0 address if ETH)
     * @param minToTokens The minimum acceptable quantity of tokens to receive. Reverts otherwise
     * @param swapTarget Excecution target for the swap or zap
     * @param swapData DEX or Zap data
     * @param affiliate Affiliate address
     * @return tokensRec Quantity of aTokens received
     */
    function ZapOut(
        address fromToken,
        uint256 amountIn,
        address toToken,
        uint256 minToTokens,
        address swapTarget,
        bytes calldata swapData,
        address affiliate
    ) external stopInEmergency returns (uint256 tokensRec) {
        require(fromToken == olympusZapManager.sOHM() || fromToken == olympusZapManager.wsOHM(), "fromToken must be sOHM or wsOHM");
        amountIn = _pullTokens( fromToken, amountIn );
        uint256 OHMRec = _exitOlympus( fromToken, amountIn );
        tokensRec = _fillQuote( olympusZapManager.OHM(), toToken, OHMRec, swapTarget, swapData );
        require(tokensRec >= minToTokens, "High Slippage");
        uint256 totalGoodwillPortion;
        if (toToken == address(0)) {
            totalGoodwillPortion = _subtractGoodwill(ETHAddress, tokensRec, affiliate, true);
            payable(msg.sender).transfer(tokensRec - totalGoodwillPortion);
        } else {
            totalGoodwillPortion = _subtractGoodwill(toToken, tokensRec, affiliate, true);
            IERC20(toToken).safeTransfer(msg.sender, tokensRec - totalGoodwillPortion);
        }
        tokensRec = tokensRec - totalGoodwillPortion;
        emit zapOut(msg.sender, toToken, tokensRec, affiliate);
    }

    function _enterOlympus(
        uint256 amount, 
        address toToken
    ) internal returns (uint256) {
        IStaking staking = IStaking( olympusZapManager.staking() );
        address wsOHM =  olympusZapManager.wsOHM();
        _approveToken( olympusZapManager.OHM(), olympusZapManager.staking(), amount );
        if ( toToken == wsOHM ) {
            staking.stake(amount, address(this));
            staking.claim(address(this));
            _approveToken( olympusZapManager.sOHM(), wsOHM , amount);
            uint256 beforeBalance = _getBalance( wsOHM  );
            IwsOHM( wsOHM ).wrap( amount );
            uint256 wsOHMRec = _getBalance( wsOHM  ) - beforeBalance;
            IERC20( wsOHM ).safeTransfer(msg.sender, wsOHMRec);
            return wsOHMRec;
        }
        staking.stake(amount, msg.sender);
        staking.claim(msg.sender);
        return amount;
    }

    function _exitOlympus(
        address fromToken, 
        uint256 amount
    ) internal returns (uint256){
        IStaking staking = IStaking( olympusZapManager.staking() );
        if (fromToken == olympusZapManager.wsOHM()) {
            uint256 sOHMRec = IwsOHM(olympusZapManager.wsOHM()).unwrap(amount);
            _approveToken(olympusZapManager.sOHM(), address( staking ), sOHMRec);
            staking.unstake(sOHMRec, true);
            return sOHMRec;
        }
        _approveToken(olympusZapManager.sOHM(), address( staking ), amount);
        staking.unstake(amount, true);
        return amount;
    }

    function removeLiquidityReturn(
        address fromToken, 
        uint256 fromAmount
    ) external view returns (uint256 ohmAmount) {
        if (fromToken == olympusZapManager.sOHM()) {
            return fromAmount;
        } else if (fromToken == olympusZapManager.wsOHM()) {
            return IwsOHM(olympusZapManager.wsOHM()).wOHMTosOHM(fromAmount);
        }
    }

    ///////////// olympus only /////////////
    
    function update_OlympusDAO(
        address _olympusDAO
    ) external onlyOlympusDAO {
        olympusDAO = _olympusDAO;
    }

    function update_Staking(
        address _staking
    ) external onlyOlympusDAO {
        staking = _staking;
    }

    function update_sOHM(
        address _sOHM
    ) external onlyOlympusDAO {
       sOHM = _sOHM;
    }

    function update_wsOHM(
        address _wsOHM
    ) external onlyOlympusDAO {
        wsOHM = _wsOHM;
    }

    function update_BondDepos(
        address[] calldata principals,
        address[] calldata payoutTokens,
        address[] calldata depos
    ) external onlyOlympusDAO {
        require( principals.length == depos.length  && depos.length == payoutTokens.length, "array param lengths must match" );
        // update depos for each principal
        for ( uint i; i < principals.length; i++) {
            principalToDepository[ principals[ i ] ][ payoutTokens[ i ] ] = depos[ i ];
            // max approve depo to save on gas
            IERC20( principals[ i ] ).approve( depos[ i ], type( uint ).max );
            // set depo as an approved target
            approvedTargets[ depos[ i ] ] = true;
        }
    }
}
