// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*
    _    _  ___  _   _ _   _ ____
   | \  / |/ _ \| | | | \ | |  _ \
   | |\/| | | | | | | |  \| | | | \
   | |  | | |_| | |_| | |\  | |_| /
   |_|  |_|\___/ \___/|_| \_|____/


*
* MIT License
* ===========
*
* Copyright (c) 2021 MOUND FINANCE
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "./library/PausableUpgradeable.sol";
import "./library/SafeToken.sol";
import "./library/WhitelistUpgradeable.sol";
import { VaultConstant } from "./library/VaultConstant.sol";
import "./library/VaultConstant.sol";

import "./interfaces/IPriceCalculator.sol";


contract VaultMND is PausableUpgradeable, WhitelistUpgradeable, ReentrancyGuardUpgradeable {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint;
    using SafeToken for address;

    /* ========== CONSTANT ========== */

    IPriceCalculator public constant priceCalculator = IPriceCalculator(0xF5BF8A9249e3cc4cB684E3f23db9669323d4FB7d);
    address public constant MND = 0x4c97c901B5147F8C1C7Ce3c5cF3eB83B44F244fE;

    /* ========== STATE VARIABLES ========== */

    IBEP20 public stakingToken;

    address public rewardsDistribution;

    uint public periodFinish;
    uint public rewardsDuration;
    uint public totalSupply;

    address[] private _rewardTokens;
    mapping(address => VaultConstant.RewardInfo) public rewards;
    mapping(address => mapping(address => uint)) public userRewardPerToken;
    mapping(address => mapping(address => uint)) public userRewardPerTokenPaid;

    mapping(address => uint) private _balances;

    /* ========== EVENTS ========== */

    event Deposited(address indexed user, uint amount);
    event Withdrawn(address indexed user, uint amount);

    event RewardsAdded(uint[] amounts);
    event RewardsPaid(address indexed user, address token, uint amount);
    event Recovered(address token, uint amount);

    /* ========== INITIALIZER ========== */

    function initialize(address _stakingToken) external initializer {
        __PausableUpgradeable_init();
        __ReentrancyGuard_init();

        stakingToken = IBEP20(_stakingToken);
        rewardsDuration = 30 days;
    }

    /* ========== MODIFIERS ========== */

    modifier onlyRewardsDistribution() {
        require(msg.sender == rewardsDistribution, "VaultMND: caller is not the rewardsDistribution");
        _;
    }

    modifier updateRewards(address account) {
        for (uint i = 0; i < _rewardTokens.length; i++) {
            VaultConstant.RewardInfo storage rewardInfo = rewards[_rewardTokens[i]];
            rewardInfo.rewardPerTokenStored = rewardPerToken(rewardInfo.token);
            rewardInfo.lastUpdateTime = lastTimeRewardApplicable();

            if (account != address(0)) {
                userRewardPerToken[account][rewardInfo.token] = earnedPerToken(account, rewardInfo.token);
                userRewardPerTokenPaid[account][rewardInfo.token] = rewardInfo.rewardPerTokenStored;
            }
        }
        _;
    }

    /* ========== VIEWS ========== */

    function balanceOf(address account) public view returns (uint) {
        return _balances[account];
    }

    function earned(address account) public view returns (uint[] memory) {
        uint[] memory pendingRewards = new uint[](_rewardTokens.length);
        for (uint i = 0; i < _rewardTokens.length; i++) {
            pendingRewards[i] = earnedPerToken(account, _rewardTokens[i]);
        }
        return pendingRewards;
    }

    function earnedPerToken(address account, address token) public view returns (uint) {
        return _balances[account].mul(
            rewardPerToken(token).sub(userRewardPerTokenPaid[account][token])
        ).div(1e18).add(userRewardPerToken[account][token]);
    }

    function rewardTokens() public view returns (address[] memory) {
        return _rewardTokens;
    }

    function rewardPerToken(address token) public view returns (uint) {
        if (totalSupply == 0) return rewards[token].rewardPerTokenStored;
        return rewards[token].rewardPerTokenStored.add(
            lastTimeRewardApplicable().sub(rewards[token].lastUpdateTime).mul(rewards[token].rewardRate).mul(1e18).div(totalSupply)
        );
    }

    function lastTimeRewardApplicable() public view returns (uint) {
        return Math.min(block.timestamp, periodFinish);
    }

    function infoOf(address account) public view returns (VaultConstant.VaultInfo memory vaultInfo) {
        (, uint priceOfMND) = priceCalculator.valueOfAsset(MND, 1e18);
        vaultInfo.balance = balanceOf(account);
        vaultInfo.balanceInUSD = balanceOf(account).mul(priceOfMND).div(1e18);
        vaultInfo.totalSupply = totalSupply;
        vaultInfo.tvl = totalSupply.mul(priceOfMND).div(1e18);
        vaultInfo.rewards = new VaultConstant.UserReward[](_rewardTokens.length);
        for(uint i = 0; i < _rewardTokens.length; i++) {
            vaultInfo.rewards[i].token = _rewardTokens[i];
            uint _earned = earnedPerToken(account, _rewardTokens[i]);
            vaultInfo.rewards[i].amount = _earned;
            (, uint usd) = priceCalculator.valueOfAsset(_rewardTokens[i], _earned);
            vaultInfo.rewards[i].usd = usd;
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function addRewardsToken(address _rewardsToken) external onlyOwner {
        require(_rewardsToken != address(0), "VaultMND: invalid zero address");
        require(rewards[_rewardsToken].token == address(0), "VaultMND: duplicated rewards token");
        rewards[_rewardsToken] = VaultConstant.RewardInfo(_rewardsToken, 0, 0, 0);
        _rewardTokens.push(_rewardsToken);
    }

    function setRewardsDuration(uint _rewardsDuration) external onlyOwner {
        require(periodFinish == 0 || block.timestamp > periodFinish, "VaultMND: invalid rewards duration");
        rewardsDuration = _rewardsDuration;
    }

    function setRewardsDistribution(address _rewardsDistribution) external onlyOwner {
        rewardsDistribution = _rewardsDistribution;
    }

    function notifyRewardAmounts(uint[] memory amounts) external onlyRewardsDistribution updateRewards(address(0)) {
        for (uint i = 0; i < _rewardTokens.length; i++) {
            VaultConstant.RewardInfo storage rewardInfo = rewards[_rewardTokens[i]];
            if (block.timestamp >= periodFinish) {
                rewardInfo.rewardRate = amounts[i].div(rewardsDuration);
            } else {
                uint remaining = periodFinish.sub(block.timestamp);
                uint leftover = remaining.mul(rewardInfo.rewardRate);
                rewardInfo.rewardRate = amounts[i].add(leftover).div(rewardsDuration);
            }
            rewardInfo.lastUpdateTime = block.timestamp;

            // Ensure the provided reward amount is not more than the balance in the contract.
            // This keeps the reward rate in the right range, preventing overflows due to
            // very high values of rewardRate in the earned and rewardsPerToken functions;
            // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.

            require(rewardInfo.rewardRate <= IBEP20(rewardInfo.token).balanceOf(address(this)).div(rewardsDuration), "VaultMND: invalid rewards amount");
        }

        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardsAdded(amounts);
    }

    /* ========== MUTATE FUNCTIONS ========== */

    function deposit(uint _amount) public {
        _deposit(_amount, msg.sender);
    }

    function depositAll() public {
        _deposit(stakingToken.balanceOf(msg.sender), msg.sender);
    }

    function withdraw(uint _amount) public nonReentrant notPaused updateRewards(msg.sender) {
        require(_amount > 0, "VaultMND: invalid amount");

        totalSupply = totalSupply.sub(_amount);
        _balances[msg.sender] = _balances[msg.sender].sub(_amount);
        stakingToken.safeTransfer(msg.sender, _amount);
        emit Withdrawn(msg.sender, _amount);
    }

    function withdrawAll() external {
        uint amount = _balances[msg.sender];
        if (amount > 0) {
            withdraw(amount);
        }

        getReward();
    }

    function getReward() public nonReentrant updateRewards(msg.sender) {
        for (uint i = 0; i < _rewardTokens.length; i++) {
            uint reward = userRewardPerToken[msg.sender][_rewardTokens[i]];
            if (reward > 0) {
                userRewardPerToken[msg.sender][_rewardTokens[i]] = 0;
                IBEP20(_rewardTokens[i]).safeTransfer(msg.sender, reward);
                emit RewardsPaid(msg.sender, _rewardTokens[i], reward);
            }
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _deposit(uint _amount, address _to) private nonReentrant notPaused updateRewards(_to) {
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        totalSupply = totalSupply.add(_amount);
        _balances[_to] = _balances[_to].add(_amount);

        emit Deposited(_to, _amount);
    }
}