// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import "../src/MatchingEngine.sol";

import { IAaveV3Pool } from "../src/interfaces/IAaveV3Pool.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAavePool is IAaveV3Pool {
    MockERC20 public token;
    MockERC20 public aToken;

    constructor(address _token, address _aToken) {
        token = MockERC20(_token);
        aToken = MockERC20(_aToken);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        token.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        aToken.burn(msg.sender, amount);
        token.transfer(to, amount);
        return amount;
    }

    function getReserveData(address asset) external view returns (ReserveData memory) {
        return ReserveData({
            configuration: ReserveConfigurationMap(0),
            liquidityIndex: 0,
            currentLiquidityRate: 0,
            variableBorrowIndex: 0,
            currentVariableBorrowRate: 0,
            currentStableBorrowRate: 0,
            lastUpdateTimestamp: 0,
            id: 0,
            aTokenAddress: address(aToken),
            stableDebtTokenAddress: address(0),
            variableDebtTokenAddress: address(0),
            interestRateStrategyAddress: address(0),
            accruedToTreasury: 0,
            unbacked: 0,
            isolationModeTotalDebt: 0
        });
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MatchingEngineTest is Test {
    MatchingEngine matcher;
    MockERC20 token;
    MockERC20 aToken;
    MockAavePool aavePool;

    address alice = address(0xA);
    address bob = address(0xB);
    address charlie = address(0xC);

    function setUp() public {
        token    = new MockERC20("Token", "TOK");
        aToken   = new MockERC20("aToken", "aTOK");
        aavePool = new MockAavePool(address(token), address(aToken));

        matcher = new MatchingEngine(address(token), address(aavePool));

        token.mint(alice, 1000 ether);
        token.mint(bob, 1000 ether);
        token.mint(charlie, 1000 ether);

        vm.prank(alice);
        token.approve(address(matcher), type(uint256).max);
        vm.prank(bob);
        token.approve(address(matcher), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(matcher), type(uint256).max);
    }

    function testlendAndAaveDeposit() public {
        vm.prank(alice);
        matcher.lend(100 ether, 100); // 100 bps

        assertEq(token.balanceOf(address(aavePool)), 100 ether);
        assertEq(aToken.balanceOf(address(matcher)), 100 ether);
        assertEq(matcher.totalUnmatchedPrincipal(), 100 ether);
    }

    function testCancelLendAndAaveWithdraw() public {
        vm.prank(alice);
        matcher.lend(100 ether, 100);

        // Simulate some yield
        vm.prank(address(aavePool));
        aToken.mint(address(matcher), 5 ether); // Extra yield
        token.mint(address(aavePool), 5 ether);

        vm.prank(alice);
        matcher.cancelLend(1);

        assertEq(token.balanceOf(alice), 1005 ether); // 1000 - 100 + 105
        assertEq(aToken.balanceOf(address(matcher)), 0);
        assertEq(matcher.totalUnmatchedPrincipal(), 0);
    }

    function testborrowNoDeposit() public {
        vm.prank(bob);
        matcher.borrow(50 ether, 200);

        assertEq(token.balanceOf(bob), 1000 ether); // No transfer
    }

    function testSimpleMatchAndPartialFill() public {
        vm.prank(alice);
        matcher.lend(100 ether, 100);

        vm.prank(bob);
        matcher.borrow(150 ether, 200);

        matcher.matchOrder(10);

        // Match 100 at rate (100+200)/2 = 150 bps
        assertEq(token.balanceOf(bob), 1100 ether);
        assertEq(aToken.balanceOf(address(matcher)), 0);
        assertEq(matcher.totalUnmatchedPrincipal(), 0);

        // Borrower order remaining 50
        Order memory bOrder = matcher.getBorrowerOrder(1);
        assertEq(bOrder.remaining, 50 ether);

        // Lender order removed
        Order memory lOrder = matcher.getLenderOrder(1);
        assertEq(lOrder.owner, address(0));

        // Loan created
        Loan memory loan = matcher.getLoan(1);
        assertEq(loan.principal, 100 ether);
        assertEq(loan.rateBps, 150);
        assertTrue(loan.active);
    }

    function testPartialFillMultiple() public {
        vm.prank(alice);
        matcher.lend(100 ether, 100);

        vm.prank(charlie);
        matcher.lend(50 ether, 150);

        vm.prank(bob);
        matcher.borrow(120 ether, 200);

        matcher.matchOrder(10);

        // First match alice 100 @100 <=200, rate 150
        // Then partial charlie 20 @150 <=200, rate 175
        // bob remaining 0

        assertEq(token.balanceOf(bob), 1120 ether); // 1000 + 120

        // Loans
        Loan memory loan1 = matcher.getLoan(1);
        assertEq(loan1.principal, 100 ether);
        assertEq(loan1.rateBps, 150);

        Loan memory loan2 = matcher.getLoan(2);
        assertEq(loan2.principal, 20 ether);
        assertEq(loan2.rateBps, 175);

        // Charlie remaining 30
        Order memory cOrder = matcher.getLenderOrder(2);
        assertEq(cOrder.remaining, 30 ether);
    }

    function testNoMatchRateMismatch() public {
        vm.prank(alice);
        matcher.lend(100 ether, 300);

        vm.prank(bob);
        matcher.borrow(100 ether, 200);

        matcher.matchOrder(10);

        // No match since 300 > 200
        assertEq(token.balanceOf(bob),               1000 ether);
        assertEq(aToken.balanceOf(address(matcher)), 100 ether);
    }

    function testRepay() public {
        vm.prank(alice);
        matcher.lend(100 ether, 100);

        vm.prank(bob);
        matcher.borrow(100 ether, 200);

        matcher.matchOrder(10);

        // Advance time 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 debt = matcher.calculateDebt(1);
        // interest = 100 * 150 / 10000 * 1 = 1.5 ether
        assertEq(debt, 101.5 ether);

        vm.prank(bob);
        token.approve(address(matcher), debt);
        vm.prank(bob);
        matcher.repay(1);
    }

    function testCancelBorrow() public {
        vm.prank(bob);
        matcher.borrow(100 ether, 200);

        vm.prank(bob);
        matcher.cancelBorrow(1);

        Order memory bOrder = matcher.getBorrowerOrder(1);
        assertEq(bOrder.owner, address(0));
    }

}
