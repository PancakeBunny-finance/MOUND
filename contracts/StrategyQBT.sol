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
import "./library/WhitelistUpgradeable.sol";

import "./interfaces/IStrategy.sol";
import "./interfaces/IQore.sol";
import "./interfaces/IQToken.sol";
import "./library/SafeToken.sol";

contract StrategyQBT is IStrategy, WhitelistUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable{
    using SafeBEP20 for IBEP20;
    using SafeMath for uint;
    using SafeToken for address;

    /* ========== CONSTANT ========== */

    IQore private constant QORE = IQore(0xF70314eb9c7Fe7D88E6af5aa7F898b3A162dcd48);

    address private constant QBT = 0x17B7163cf1Dbd286E262ddc68b553D899B93f526;
    address private constant qQBT = 0xcD2CD343CFbe284220677C78A08B1648bFa39865;
    address private constant MND = 0x4c97c901B5147F8C1C7Ce3c5cF3eB83B44F244fE;

    uint private constant DUST = 1000;

    /* ========== STATE VARIABLES ========== */

    mapping(address => uint) public principals;

    /* ========== EVENT ========== */

    event Deposited(address indexed user, uint amount);
    event Withdrawn(address indexed user, uint amount);
    event ProfitPaid(address indexed user, uint amount);

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __PausableUpgradeable_init();
        __WhitelistUpgradeable_init();
        __ReentrancyGuard_init();

        // approve QBT
        QBT.safeApprove(qQBT, uint(-1));

        // enter the qQBT market
        address[] memory qubitMarket = new address[](1);
        qubitMarket[0] = qQBT;
        QORE.enterMarkets(qubitMarket);
    }

    /* ========== VIEWS ========== */

    function balance() public view returns (uint) {
        return IQToken(qQBT).underlyingBalanceOf(address(this));
    }

    function balanceOf(address account) public view override returns (uint) {
        require(account != address(0), "StrategyQBT: invalid account!");
        return balance();
    }

    function principalOf(address account) public view override returns (uint) {
        return principals[account];
    }

    function earned(address account) public view override returns (uint) {
        uint profit = rewardProfit();
        if (balanceOf(account) > principals[account] + DUST) {
            profit = profit.add(balanceOf(account).sub(principals[account]));
        }
        return profit;
    }

    function rewardProfit() public view returns (uint) {
        return QORE.accruedQubit(qQBT, address(this));
    }

    /* ========== RESTRICTED FUNCTION ========== */

    function deposit(uint _amount) public onlyWhitelisted nonReentrant {
        uint _before = QBT.balanceOf(address(this));
        QBT.safeTransferFrom(msg.sender, address(this), _amount);
        uint amountQBT = QBT.balanceOf(address(this)).sub(_before);

        principals[msg.sender] = principals[msg.sender].add(amountQBT);

        // supply QBT
        QORE.supply(qQBT, amountQBT);

        emit Deposited(msg.sender, amountQBT);
    }

    function depositAll() public payable override onlyWhitelisted {
        uint amount = QBT.balanceOf(msg.sender);
        deposit(amount);
    }

    function withdrawUnderlying(uint _amount) public onlyWhitelisted nonReentrant {
        require(_amount <= principals[msg.sender], "StrategyQBT: Invalid input amount");

        uint _before = QBT.balanceOf(address(this));
        QORE.redeemUnderlying(qQBT, _amount);
        uint amountQBT = QBT.balanceOf(address(this)).sub(_before);

        principals[msg.sender] = principals[msg.sender].sub(amountQBT);

        QBT.safeTransfer(msg.sender, amountQBT);

        emit Withdrawn(msg.sender, amountQBT);
    }

    function withdrawAll() public override onlyWhitelisted {
        uint _before = QBT.balanceOf(address(this));
        QORE.redeemToken(qQBT, IQToken(qQBT).balanceOf(address(this)));
        QORE.claimQubit(qQBT);
        uint amountQBT = QBT.balanceOf(address(this)).sub(_before);

        delete principals[msg.sender];

        QBT.safeTransfer(msg.sender, amountQBT);
        emit Withdrawn(msg.sender, amountQBT);
    }

    function getReward() public override onlyWhitelisted {
        uint _before = QBT.balanceOf(address(this));

        // supply interest
        if (balanceOf(msg.sender) > principals[msg.sender] + DUST) {
            QORE.redeemUnderlying(qQBT, balanceOf(msg.sender).sub(principals[msg.sender]));
        }

        // supply reward
        QORE.claimQubit(qQBT);
        uint claimedQBT = QBT.balanceOf(address(this)).sub(_before);

        QBT.safeTransfer(msg.sender, claimedQBT);
        emit ProfitPaid(msg.sender, claimedQBT);
    }
}
