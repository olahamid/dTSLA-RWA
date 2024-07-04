// SPDX-License-Identifier: MIT 
pragma solidity 0.8.23;

interface IDTSLA {
    function sendMintRequest(uint256 amount) external returns (bytes32);

    function withdraw() external;

    function sendRedeemRequest(uint256 amountdTSLA) external ;

    
}