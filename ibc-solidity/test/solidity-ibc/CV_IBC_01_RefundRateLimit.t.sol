// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

// solhint-disable custom-errors,max-line-length,gas-small-strings

import { DummyLightClientIntegrationTest } from "./DummyLightClientIntegrationTest.t.sol";
import { IICS02ClientMsgs } from "../../contracts/msgs/IICS02ClientMsgs.sol";
import { IICS26RouterMsgs } from "../../contracts/msgs/IICS26RouterMsgs.sol";
import { IICS20TransferMsgs } from "../../contracts/msgs/IICS20TransferMsgs.sol";
import { IRateLimitErrors } from "../../contracts/errors/IRateLimitErrors.sol";
import { ICS20Lib } from "../../contracts/utils/ICS20Lib.sol";
import { Escrow } from "../../contracts/utils/Escrow.sol";

contract RefundRateLimitInvariantTest is DummyLightClientIntegrationTest {
    uint256 internal constant RATE_LIMIT = 1000 ether;

    function _bootstrapEscrowWithLiquidity(uint256 liquidity) internal returns (Escrow escrow) {
        address liquidityUser = makeAddr("liquidityUser");
        erc20.mint(liquidityUser, liquidity);
        vm.prank(liquidityUser);
        erc20.approve(address(ics20Transfer), liquidity);

        IICS20TransferMsgs.SendTransferMsg memory seedMsg = IICS20TransferMsgs.SendTransferMsg({
            denom: address(erc20),
            amount: liquidity,
            receiver: defaultReceiverStr,
            sourceClient: clientIdentifier,
            destPort: ICS20Lib.DEFAULT_PORT_ID,
            timeoutTimestamp: uint64(block.timestamp + 1000),
            memo: "seed"
        });
        vm.prank(liquidityUser);
        ics20Transfer.sendTransfer(seedMsg);

        escrow = Escrow(ics20Transfer.getEscrow(clientIdentifier));
        escrow.setRateLimit(address(erc20), RATE_LIMIT);

        // Start test scenarios on a clean UTC day boundary window
        vm.warp(block.timestamp + 1 days);
        assertEq(escrow.getDailyUsage(address(erc20)), 0);
    }

    /// @notice Post-patch verification of Patch v2:
    ///         sendTransfer with amount > L is rejected upfront with RateLimitExceeded,
    ///         keeping user funds intact instead of creating an unrefundable packet;
    ///         boundary amount == L succeeds and refunds cleanly after daily reset.
    function test_patched_aboveLimitSendRejectedAndExactLimitRefunds() public {
        Escrow escrow = _bootstrapEscrowWithLiquidity(RATE_LIMIT);

        uint256 overLimitAmount = RATE_LIMIT + 500 ether; // 1,500 ether > 1,000 ether
        erc20.mint(defaultSender, overLimitAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), overLimitAmount);

        IICS20TransferMsgs.SendTransferMsg memory overLimitMsg = IICS20TransferMsgs.SendTransferMsg({
            denom: address(erc20),
            amount: overLimitAmount,
            receiver: defaultReceiverStr,
            sourceClient: clientIdentifier,
            destPort: ICS20Lib.DEFAULT_PORT_ID,
            timeoutTimestamp: uint64(block.timestamp + 1000),
            memo: "over-limit"
        });

        // 1. Outbound sendTransfer(amount > L) is rejected upfront with RateLimitExceeded
        vm.prank(defaultSender);
        vm.expectRevert(
            abi.encodeWithSelector(IRateLimitErrors.RateLimitExceeded.selector, RATE_LIMIT, overLimitAmount)
        );
        ics20Transfer.sendTransfer(overLimitMsg);

        // User retains 100% of principal
        assertEq(erc20.balanceOf(defaultSender), overLimitAmount);

        // 2. Boundary transfer with amount == L succeeds and can be refunded after daily reset
        IICS26RouterMsgs.Packet memory exactPacket = _sendICS20TransferPacket(
            defaultSenderStr, defaultReceiverStr, address(erc20), RATE_LIMIT, clientIdentifier
        );
        assertEq(erc20.balanceOf(defaultSender), 500 ether);

        vm.warp(exactPacket.timeoutTimestamp + 1 days);
        assertEq(escrow.getDailyUsage(address(erc20)), 0);
        lightClient.setMembershipResult(uint64(block.timestamp), false);
        ics26Router.timeoutPacket(
            IICS26RouterMsgs.MsgTimeoutPacket({
                packet: exactPacket,
                proofTimeout: bytes("doesntmatter"),
                proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 })
            })
        );

        assertEq(relayerHelper.queryPacketCommitment(exactPacket.sourceClient, exactPacket.sequence), bytes32(0));
        assertEq(erc20.balanceOf(defaultSender), overLimitAmount);
    }

    /// @notice Verifies that when amount <= L, a temporary quota collision on Day 0 clears
    ///         automatically and timeoutPacket refunds the sender after the daily window resets.
    function test_withinLimitRefundSucceedsAfterDailyReset() public {
        Escrow escrow = _bootstrapEscrowWithLiquidity(RATE_LIMIT);

        uint256 withinLimitAmount = 800 ether; // <= 1,000 ether
        erc20.mint(defaultSender, withinLimitAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), withinLimitAmount);

        IICS26RouterMsgs.Packet memory packet = _sendICS20TransferPacket(
            defaultSenderStr, defaultReceiverStr, address(erc20), withinLimitAmount, clientIdentifier
        );
        assertEq(erc20.balanceOf(defaultSender), 0);
        assertEq(escrow.getDailyUsage(address(erc20)), 0);

        // Inbound return of native erc20 consumes 500 ether of today's rate limit
        string memory returningDenom =
            string(abi.encodePacked(ICS20Lib.DEFAULT_PORT_ID, "/", counterpartyId, "/", erc20AddressStr));
        _receiveICS20Transfer(
            "cosmos1mhmwgrfrcrdex5gnr0vcqt90wknunsxej63feh", defaultReceiverStr, returningDenom, 500 ether
        );
        assertEq(escrow.getDailyUsage(address(erc20)), 500 ether);

        IICS26RouterMsgs.MsgTimeoutPacket memory timeoutMsg = IICS26RouterMsgs.MsgTimeoutPacket({
            packet: packet,
            proofTimeout: bytes("doesntmatter"),
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 })
        });

        // Same day: 500 + 800 = 1,300 > 1,000 -> delayed until window resets
        vm.warp(packet.timeoutTimestamp);
        lightClient.setMembershipResult(uint64(block.timestamp), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRateLimitErrors.RateLimitExceeded.selector, RATE_LIMIT, 500 ether + withinLimitAmount
            )
        );
        ics26Router.timeoutPacket(timeoutMsg);

        // Next UTC day reset: dailyUsage resets to 0, refund of 800 ether succeeds
        vm.warp(block.timestamp + 1 days);
        assertEq(escrow.getDailyUsage(address(erc20)), 0);
        lightClient.setMembershipResult(uint64(block.timestamp), false);
        ics26Router.timeoutPacket(timeoutMsg);

        assertEq(relayerHelper.queryPacketCommitment(packet.sourceClient, packet.sequence), bytes32(0));
        assertEq(erc20.balanceOf(defaultSender), withinLimitAmount);
        assertEq(escrow.getDailyUsage(address(erc20)), withinLimitAmount);
    }
}
