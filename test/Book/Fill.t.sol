// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IFloodFillCallback} from "src/interfaces/IFloodFillCallback.sol";
import {
    Book__SameToken,
    Book__ZeroAmount,
    Book__SentToBlackHole,
    Book__InvalidToken,
    Book__TradeNotInFillableState,
    Book__NotTrader,
    Book__TradeNotCancelable,
    Book__AmountOutTooLow,
    Book__NotWeth,
    Book__InvalidValue,
    TradeStatus
} from "src/Book.sol";
import {TradeFixture} from "./Fixtures.sol";


contract MockFloodFillCallee is IFloodFillCallback { 
    function onFloodFill(bytes calldata data) external override {}
}

contract FillTest is TradeFixture, MockFloodFillCallee {
    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();
    }

    function testFillTrade(uint256 amountIn, uint256 amountOut) public {
        vm.assume(amountIn > 0);
        vm.assume(amountOut > testAmountOutMin);
        vm.assume(amountIn < type(uint256).max / testRelayerRefundPct - 1);

        deal(testTokenIn, alice, amountIn);
        (uint256 tradeIndex, bytes32 tradeId) =
            _requestTrade(testTokenIn, testTokenOut, amountIn, testAmountOutMin, testRecipient, alice, false);

        deal(testTokenOut, bob, amountOut);
        uint256 bobBalanceOutBefore = IERC20(testTokenOut).balanceOf(bob);
        uint256 bobBalanceInBefore = IERC20(testTokenIn).balanceOf(bob);
        uint256 recipientBalanceBefore = IERC20(testTokenOut).balanceOf(testRecipient);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(book));
        emit TradeFilled(bob, tradeIndex, amountOut, alice);
        book.fillTrade(
            testTokenIn,
            testTokenOut,
            amountIn,
            testAmountOutMin,
            testRecipient,
            tradeIndex,
            alice,
            amountOut,
            bytes("")
        );
        // Check bob submitted amountOut tokens
        assertEq(
            IERC20(testTokenOut).balanceOf(bob) + amountOut,
            bobBalanceOutBefore,
            "bob should have sent amountOut tokens"
        );
        // Check bob got relayerRefundPct * amountIn tokens
        uint256 bobExpectedTokens = (amountIn * testRelayerRefundPct) / 100;

        assertEq(
            IERC20(testTokenIn).balanceOf(bob),
            bobBalanceInBefore + bobExpectedTokens,
            "bob should have received some tokens"
        );
        // Check the recipient received amountOut tokens
        assertEq(
            IERC20(testTokenOut).balanceOf(testRecipient),
            recipientBalanceBefore + amountOut,
            "recipient should have received amountOut tokens"
        );

        uint256 filledAtInStorage =
            stdstore.target(address(book)).sig(book.filledAtBlock.selector).with_key(tradeId).read_uint();
        assertEq(filledAtInStorage, block.number);

        address filledByInStorage =
            stdstore.target(address(book)).sig(book.filledBy.selector).with_key(tradeId).read_address();
        assertEq(filledByInStorage, bob);
    }

    function testCannotFillUninitialized() public {
        bytes32 tradeId =
            _getTradeId(testTokenIn, testTokenOut, testAmountIn, testAmountOutMin, testRecipient, 1, testTrader);
        // This should fail as the trade has not been requested.
        vm.expectRevert(abi.encodeWithSelector(Book__TradeNotInFillableState.selector, tradeId));
        book.fillTrade(
            testTokenIn, testTokenOut, testAmountIn, testAmountOutMin, testRecipient, 1, testTrader, 1, bytes("")
        );
    }

    function testCannotFillIfAlreadyFilled() public {
        // Simulate a trade request. We assume that the request is valid and executed correctly.
        uint256 tradeIndex = book.numberOfTrades() + 1;
        bytes32 tradeId = _getTradeId(
            testTokenIn, testTokenOut, testAmountIn, testAmountOutMin, testRecipient, tradeIndex, testTrader
        );

        // Artificially fill&dispute the trade at the past block.
        stdstore.target(address(book)).sig(book.filledAtBlock.selector).with_key(tradeId).checked_write(block.number);
        vm.expectRevert(abi.encodeWithSelector(Book__TradeNotInFillableState.selector, tradeId));
        book.fillTrade(
            testTokenIn,
            testTokenOut,
            testAmountIn,
            testAmountOutMin,
            testRecipient,
            tradeIndex,
            testTrader,
            testAmountOutMin + 1,
            bytes("")
        );
    }

    function testCannotFillIfNoTokens(uint256 amountOut) public {
        vm.assume(amountOut > 0);
        bytes32 tradeId = _getTradeId(testTokenIn, testTokenOut, testAmountIn, 0, testRecipient, 1, testTrader);
        // simulate a request
        stdstore.target(address(book)).sig(book.status.selector).with_key(tradeId).checked_write(
            uint256(TradeStatus.REQUESTED)
        );
        vm.prank(bob);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds balance"));
        book.fillTrade(testTokenIn, testTokenOut, testAmountIn, 0, testRecipient, 1, testTrader, amountOut, bytes(""));
    }

    function testCannotFillIfAmountOutIsLessThanMin(uint256 minAmountOut) public {
        vm.assume(minAmountOut > 1);
        bytes32 tradeId =
            _getTradeId(testTokenIn, testTokenOut, testAmountIn, minAmountOut, testRecipient, 1, testTrader);
        // simulate a request
        stdstore.target(address(book)).sig(book.status.selector).with_key(tradeId).checked_write(
            uint256(TradeStatus.REQUESTED)
        );
        uint256 amountOut = minAmountOut - 1;
        vm.prank(bob);
        vm.expectRevert(Book__AmountOutTooLow.selector);
        book.fillTrade(
            testTokenIn, testTokenOut, testAmountIn, minAmountOut, testRecipient, 1, testTrader, amountOut, bytes("")
        );
    }



    function testFillWithUnwrap() public {
        testTokenIn = USDC;
        testTokenOut = WETH;
        testAmountIn = 2e9;
        uint256 amountOut = 1 ether;

        deal(testTokenIn, alice, testAmountIn);
        (uint256 tradeIndex, bytes32 tradeId) =
            _requestTrade(testTokenIn, testTokenOut, testAmountIn, testAmountOutMin, testRecipient, alice, true);

        deal(testTokenOut, bob, amountOut);
        uint256 bobBalanceOutBefore = IERC20(testTokenOut).balanceOf(bob);
        uint256 bobBalanceInBefore = IERC20(testTokenIn).balanceOf(bob);
        uint256 recipientBalanceBefore = IERC20(testTokenOut).balanceOf(testRecipient);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(book));
        emit TradeFilled(bob, tradeIndex, amountOut, alice);
        book.fillTrade(
            testTokenIn,
            testTokenOut,
            testAmountIn,
            testAmountOutMin,
            testRecipient,
            tradeIndex,
            alice,
            amountOut,
            bytes("")
        );
        // Check bob submitted amountOut tokens
        assertEq(
            IERC20(testTokenOut).balanceOf(bob) + amountOut,
            bobBalanceOutBefore,
            "bob should have sent amountOut tokens"
        );
        // Check bob got relayerRefundPct * amountIn tokens
        uint256 bobExpectedTokens = (testAmountIn * testRelayerRefundPct) / 100;

        assertEq(
            IERC20(testTokenIn).balanceOf(bob),
            bobBalanceInBefore + bobExpectedTokens,
            "bob should have received some tokens"
        );
        // Check the recipient received amountOut ethers
        assertEq(
            testRecipient.balance, recipientBalanceBefore + amountOut, "recipient should have received amountOut tokens"
        );

        uint256 filledAtInStorage =
            stdstore.target(address(book)).sig(book.filledAtBlock.selector).with_key(tradeId).read_uint();
        assertEq(filledAtInStorage, block.number);

        address filledByInStorage =
            stdstore.target(address(book)).sig(book.filledBy.selector).with_key(tradeId).read_address();
        assertEq(filledByInStorage, bob);
    }

    function testFillWithCallback() public {
        // Simulate a trade request. We assume that the request is valid and executed correctly.
        uint256 tradeIndex = book.numberOfTrades() + 1;
        bytes32 tradeId = _getTradeId(
            testTokenIn, testTokenOut, testAmountIn, testAmountOutMin, testRecipient, tradeIndex, testTrader
        );
        // simulate the request
        stdstore.target(address(book)).sig(book.status.selector).with_key(tradeId).checked_write(
            uint256(TradeStatus.REQUESTED)
        );
        // give the book the tokens in of the trade
        deal(testTokenIn, address(book), testAmountIn);
        // give this contract the tokens out of the trade
        deal(testTokenOut, address(this), testAmountOutMin);
        IERC20(testTokenOut).approve(address(book), testAmountOutMin);
        bytes memory data = abi.encode("Hello Flood");
        vm.expectCall(
            address(this),
            abi.encodeCall(IFloodFillCallback.onFloodFill, (data))
        );
        book.fillTrade(
            testTokenIn,
            testTokenOut,
            testAmountIn,
            testAmountOutMin,
            testRecipient,
            tradeIndex,
            testTrader,
            testAmountOutMin,
            data 
        ); 
    }
}