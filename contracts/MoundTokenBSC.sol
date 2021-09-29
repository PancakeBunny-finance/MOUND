// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

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

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "./interfaces/IMoundToken.sol";
import "./interfaces/IPriceCalculator.sol";
import "./interfaces/IRewardPool.sol";
import "./interfaces/IStrategyPayable.sol";
import "./library/BEP20Upgradeable.sol";
import "./library/SafeToken.sol";


contract MoundTokenBSC is IMoundToken, BEP20Upgradeable {
    using SafeToken for address;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANT ========== */

    IPriceCalculator public constant priceCalculator = IPriceCalculator(0xF5BF8A9249e3cc4cB684E3f23db9669323d4FB7d);
    IRewardPool public constant MND_VAULT = IRewardPool(0x7a7f11ef54fD7ce28808ec3F0C4178aFDfc91493);

    uint public constant RESERVE_RATIO = 15;

    /* ========== STATE VARIABLES ========== */

    mapping(address => bool) public minters;

    address[] private _portfolioList;
    mapping(address => PortfolioInfo) public portfolios;

    address public keeper;

    mapping(address => uint) private _profitSupply;

    /* ========== EVENTS ========== */

    event Deposited(address indexed user, address indexed token, uint amount);

    receive() external payable {}

    /* ========== MODIFIERS ========== */

    modifier onlyMinter() {
        require(owner() == msg.sender || minters[msg.sender], "MoundToken: caller is not the minter");
        _;
    }

    modifier onlyKeeper() {
        require(keeper == msg.sender || owner() == msg.sender, "MoundToken: caller is not keeper");
        _;
    }

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __BEP20__init("Mound Token", "MND", 18);
    }

    /* ========== VIEWS ========== */

    function tvl() public view override returns (uint valueInUSD) {
        valueInUSD = 0;

        for (uint i = 0; i < _portfolioList.length; i++) {
            valueInUSD = valueInUSD.add(portfolioValueOf(_portfolioList[i]));
        }
    }

    function portfolioValueOf(address token) public view returns (uint) {
        uint price;
        if (token == address(0)) {
            price = priceCalculator.priceOfBNB();
        } else {
            (, price) = priceCalculator.valueOfAsset(token, 1e18);
        }

        return portfolioBalanceOf(token).mul(price).div(1e18);
    }

    function portfolioBalanceOf(address token) public view returns (uint) {
        uint balance = token == address(0) ? address(this).balance : IBEP20(token).balanceOf(address(this));
        uint stakedBalance = portfolios[token].strategy == address(0)
        ? 0
        : IStrategy(portfolios[token].strategy).balanceOf(address(this));
        return stakedBalance.add(balance);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function mint(address account, uint amount) public override onlyMinter {
        _mint(account, amount);
        _mint(owner(), amount.mul(RESERVE_RATIO).div(100));
    }

    function setMinter(address account, bool isMinter) external onlyOwner {
        minters[account] = isMinter;
    }

    function setKeeper(address _keeper) external onlyOwner {
        require(_keeper != address(0), "MoundToken: invalid address");
        keeper = _keeper;
    }

    function addPortfolio(address token, address strategy) external override onlyOwner {
        require(portfolios[token].token == address(0), "MoundToken: portfolio is already set");
        portfolios[token] = PortfolioInfo(token, strategy);
        _portfolioList.push(token);

        if (token != address(0) && strategy != address(0)) {
            IBEP20(token).safeApprove(strategy, 0);
            IBEP20(token).safeApprove(strategy, uint(-1));
        }
    }

    function updatePortfolioStrategy(address token, address strategy) external override onlyOwner {
        require(strategy != address(0), "MoundToken: strategy must not be zero");

        uint _before = token == address(0) ? address(this).balance : IBEP20(token).balanceOf(address(this));
        if (portfolios[token].strategy != address(0) &&
            IStrategy(portfolios[token].strategy).balanceOf(address(this)) > 0) {
            IStrategy(portfolios[token].strategy).withdrawAll();
        }
        uint migrationAmount = token == address(0) ? address(this).balance.sub(_before) : IBEP20(token).balanceOf(address(this)).sub(_before);

        if (portfolios[token].strategy != address(0) && token != address(0)) {
            IBEP20(token).approve(portfolios[token].strategy, 0);
        }

        portfolios[token].strategy = strategy;

        if (token != address(0)) {
            IBEP20(token).safeApprove(strategy, 0);
            IBEP20(token).safeApprove(strategy, uint(-1));
        }

        if (migrationAmount > 0) {
            if (token == address(0)) {
                IStrategyPayable(strategy).deposit{ value: migrationAmount }(migrationAmount);
            } else {
                IStrategyPayable(strategy).deposit(migrationAmount);
            }
        }
    }

    function harvest() external onlyKeeper {
        address[] memory rewards = MND_VAULT.rewardTokens();
        uint[] memory amounts = new uint[](rewards.length);
        for(uint i = 0; i < rewards.length; i++) {
            address token = rewards[i];
            if (portfolios[token].strategy != address(0)) {
                uint beforeBalance = IBEP20(token).balanceOf(address(this));

                if (IStrategy(portfolios[token].strategy).earned(address(this)) > 0) {
                    IStrategy(portfolios[token].strategy).getReward();
                }

                uint profit = IBEP20(token).balanceOf(address(this)).add(_profitSupply[token]).sub(beforeBalance);
                _profitSupply[token] = 0;
                IBEP20(token).safeTransfer(address(MND_VAULT), profit);
                amounts[i] = profit;
            }
        }

        MND_VAULT.notifyRewardAmounts(amounts);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(address token, uint amount) external payable override onlyKeeper {
        if (token == address(0)) {
            amount = msg.value;
            if (portfolios[token].strategy != address(0)) {
                IStrategy(portfolios[token].strategy).depositAll{ value: amount }();
            }
        } else {
            IBEP20(token).safeTransferFrom(msg.sender, address(this), amount);
            if (portfolios[token].strategy != address(0)) {
                IStrategy(portfolios[token].strategy).depositAll();
            }
        }

        emit Deposited(msg.sender, token, amount);
    }

    function depositRest(address token, uint amount) external onlyKeeper {
        if (portfolios[token].strategy != address(0)) {
            if (token == address(0) && address(this).balance >= amount) {
                IStrategyPayable(portfolios[token].strategy).deposit{ value: amount }(amount);
            } else if (IBEP20(token).balanceOf(address(this)) >= amount) {
                IStrategyPayable(portfolios[token].strategy).deposit(amount);
            }
        }
    }

    function supplyProfit(address token, uint amount) external payable onlyKeeper {
        require(portfolios[token].token != address(0), "MoundToken: invalid token");
        if (token != address(0)) {
            IBEP20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
        _profitSupply[token] = token != address(0) ? amount : msg.value;
    }
}
