// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "./IStrategy.sol";

interface IRewardPool is IStrategy {
    function rewardTokens() external view returns (address [] memory);

    function notifyRewardAmounts(uint[] memory amounts) external;
}