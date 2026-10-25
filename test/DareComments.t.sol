// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DareComments} from "../src/DareComments.sol";
import {HiddenList} from "../src/HiddenList.sol";
import {MockNFT} from "./mocks/MockNFT.sol";

/// @dev Text 1..500 bytes (empty and 501 revert, UTF-8 counted in bytes); kind 1/2 only; a reply's parent must be an
///      existing comment of the same (vault, kind, targetId); the event carries every field; no ETH accepted; gas of
///      a top-level post at 100/280/500 bytes and of a reply (cancun, the mainnet estimate); HiddenList takes
///      (address(comments), 3, id) like any other item. Chain for readers without an archive node: lastBlock of each
///      (vault, kind, targetId) and prevBlock in every event, walked back to 0 across threads, kinds and replies.
contract DareCommentsTest is Test {
    DareComments c;

    address constant VAULT = address(0xBA07);
    address constant VAULT2 = address(0xBA08);
    address constant WRITER = address(0xA11CE);
    address constant REPLIER = address(0xB0B);

    event Comment(
        uint256 indexed id,
        address indexed vault,
        uint256 indexed targetId,
        uint8 kind,
        uint256 parentId,
        address author,
        string text,
        uint256 prevBlock
    );

    function setUp() public {
        c = new DareComments();
    }

    function _text(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = bytes1(uint8(97 + (i % 26)));
        }
        return string(b);
    }

    // ------------------------------------------------------------------ text

    function test_EmptyTextReverts() public {
        vm.expectRevert(DareComments.BadText.selector);
        c.post(VAULT, 1, 1, 0, "");
    }

    function test_500BytesOk_501Reverts() public {
        assertEq(c.post(VAULT, 1, 1, 0, _text(500)), 1);
        vm.expectRevert(DareComments.BadText.selector);
        c.post(VAULT, 1, 1, 0, _text(501));
        assertEq(c.count(), 1);
    }

    function test_OneByteOk() public {
        assertEq(c.post(VAULT, 1, 1, 0, "k"), 1);
    }

    function test_Utf8CountedInBytes() public {
        // "é" = 2 bytes, a frog emoji = 4 bytes
        string memory utf8 = unicode"café 🐸";
        assertEq(bytes(utf8).length, 10);
        vm.recordLogs();
        c.post(VAULT, 2, 7, 0, utf8);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,, string memory text) = abi.decode(logs[0].data, (uint8, uint256, address, string));
        assertEq(text, utf8);
        // 250 two-byte letters = 500 bytes: ok; 251 = 502: reverts
        bytes memory b = new bytes(502);
        for (uint256 i; i < 502; i += 2) {
            b[i] = 0xd0;
            b[i + 1] = 0xb0;
        }
        vm.expectRevert(DareComments.BadText.selector);
        c.post(VAULT, 1, 1, 0, string(b));
        assembly {
            mstore(b, 500)
        }
        c.post(VAULT, 1, 1, 0, string(b));
    }

    // ------------------------------------------------------------------ kind

    function test_KindOnlyTaskOrProof() public {
        vm.expectRevert(DareComments.BadKind.selector);
        c.post(VAULT, 0, 1, 0, "x");
        vm.expectRevert(DareComments.BadKind.selector);
        c.post(VAULT, 3, 1, 0, "x");
        c.post(VAULT, 1, 1, 0, "x");
        c.post(VAULT, 2, 1, 0, "x");
    }

    // ------------------------------------------------------------------ parent

    function test_ReplyToSameThreadOk() public {
        uint256 root = c.post(VAULT, 1, 5, 0, "root");
        vm.prank(REPLIER);
        uint256 r1 = c.post(VAULT, 1, 5, root, "reply");
        vm.prank(WRITER);
        uint256 r2 = c.post(VAULT, 1, 5, r1, "reply to reply");
        assertEq(r1, 2);
        assertEq(r2, 3);
    }

    function test_ParentFromOtherThreadReverts() public {
        uint256 root = c.post(VAULT, 1, 5, 0, "root");
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT, 1, 6, root, "other task");
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT, 2, 5, root, "same id, proof kind");
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT2, 1, 5, root, "other vault");
    }

    function test_ParentNotYetExistingReverts() public {
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT, 1, 5, 1, "no comment 1 yet");
        c.post(VAULT, 1, 5, 0, "root");
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT, 1, 5, 2, "self / future id");
    }

    function testFuzz_ParentMustMatch(uint256 targetA, uint256 targetB, uint8 kindB) public {
        kindB = uint8(bound(kindB, 1, 2));
        uint256 root = c.post(VAULT, 1, targetA, 0, "root");
        if (targetA == targetB && kindB == 1) {
            c.post(VAULT, kindB, targetB, root, "ok");
        } else {
            vm.expectRevert(DareComments.BadParent.selector);
            c.post(VAULT, kindB, targetB, root, "bad");
        }
    }

    // ------------------------------------------------------------------ events

    function test_EventCarriesEveryField() public {
        vm.roll(40);
        vm.prank(WRITER);
        c.post(VAULT, 1, 9, 0, "first");
        vm.roll(41);
        vm.expectEmit(true, true, true, true, address(c));
        emit Comment(2, VAULT, 9, 1, 1, REPLIER, "Deadline is Friday", 40);
        vm.prank(REPLIER);
        c.post(VAULT, 1, 9, 1, "Deadline is Friday");
    }

    function test_AnyTargetIdAccepted() public {
        // the contract never reads the core: the site shows only items that exist
        c.post(VAULT, 1, type(uint256).max, 0, "x");
        c.post(address(0), 2, 0, 0, "x");
        assertEq(c.count(), 2);
    }

    // ------------------------------------------------------------------ prevBlock chain

    struct Seen {
        uint256 id;
        uint256 block;
        uint256 prev;
        uint256 thread;
    }

    Seen[] seen;

    function _postAt(uint256 blk, address vault, uint8 kind, uint256 target, uint256 parent) internal returns (uint256 id) {
        vm.roll(blk);
        vm.recordLogs();
        id = c.post(vault, kind, target, parent, "x");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,,, uint256 prev) = abi.decode(logs[0].data, (uint8, uint256, address, string, uint256));
        seen.push(Seen(id, blk, prev, uint256(keccak256(abi.encode(vault, kind, target)))));
    }

    function test_FirstCommentPrevBlockZero() public {
        assertEq(c.lastBlock(VAULT, 1, 5), 0);
        _postAt(100, VAULT, 1, 5, 0);
        assertEq(seen[0].prev, 0);
        assertEq(c.lastBlock(VAULT, 1, 5), 100);
    }

    function test_ChainWalksBackThroughOneThread() public {
        uint256 root = _postAt(100, VAULT, 1, 5, 0); // seen[0]
        _postAt(130, VAULT, 1, 5, root); // reply, seen[1]
        _postAt(130, VAULT, 1, 5, 0); // same block, seen[2]
        _postAt(500, VAULT, 1, 5, 2); // reply to reply, seen[3]
        assertEq(seen[0].prev, 0);
        assertEq(seen[1].prev, 100);
        assertEq(seen[2].prev, 130); // same block as the one before: the reader gets both from one getLogs
        assertEq(seen[3].prev, 130);
        assertEq(c.lastBlock(VAULT, 1, 5), 500);
    }

    function test_ThreadsKindsVaultsHaveSeparateChains() public {
        _postAt(10, VAULT, 1, 5, 0); // task 5
        _postAt(20, VAULT, 2, 5, 0); // proof 5: own chain, same targetId
        _postAt(30, VAULT, 1, 6, 0); // task 6
        _postAt(40, VAULT2, 1, 5, 0); // other vault, task 5
        _postAt(50, VAULT, 1, 5, 1); // task 5 reply
        _postAt(60, VAULT, 2, 5, 2); // proof 5 reply
        assertEq(seen[1].prev, 0);
        assertEq(seen[2].prev, 0);
        assertEq(seen[3].prev, 0);
        assertEq(seen[4].prev, 10);
        assertEq(seen[5].prev, 20);
        assertEq(c.lastBlock(VAULT, 1, 5), 50);
        assertEq(c.lastBlock(VAULT, 2, 5), 60);
        assertEq(c.lastBlock(VAULT, 1, 6), 30);
        assertEq(c.lastBlock(VAULT2, 1, 5), 40);
        assertEq(c.lastBlock(VAULT2, 2, 5), 0);
    }

    function test_RevertedPostLeavesChain() public {
        _postAt(10, VAULT, 1, 5, 0);
        vm.roll(20);
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT, 1, 5, 9, "x");
        assertEq(c.lastBlock(VAULT, 1, 5), 10);
    }

    /// @dev Random posts into 3 threads over rising blocks; walking each thread from lastBlock by prevBlock visits
    ///      exactly the blocks of its comments, newest first.
    function testFuzz_WalkFindsEveryComment(uint256 seed) public {
        uint256 blk = 1000;
        uint256[3] memory n;
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 t = seed % 3;
            blk += (seed >> 8) % 3; // 0 = same block as the post before
            _postAt(blk, VAULT, 1, 100 + t, 0);
            ++n[t];
        }
        for (uint256 t; t < 3; ++t) {
            uint256 b = c.lastBlock(VAULT, 1, 100 + t);
            uint256 found;
            uint256 guard;
            while (b != 0 && guard++ < 50) {
                // the comments of thread t in block b; the next block back = prev of the earliest of them
                uint256 next = 0;
                bool first = true;
                for (uint256 k; k < seen.length; ++k) {
                    if (seen[k].block != b || seen[k].thread != uint256(keccak256(abi.encode(VAULT, uint8(1), 100 + t)))) continue;
                    ++found;
                    if (first) {
                        next = seen[k].prev;
                        first = false;
                    }
                }
                assertLt(next, b);
                b = next;
            }
            assertEq(found, n[t]);
        }
    }

    // ------------------------------------------------------------------ money

    function test_NoEthAccepted() public {
        vm.deal(WRITER, 1 ether);
        vm.prank(WRITER);
        (bool ok,) = address(c).call{value: 1}("");
        assertFalse(ok);
        vm.prank(WRITER);
        (ok,) = address(c).call{value: 1}(
            abi.encodeCall(DareComments.post, (VAULT, uint8(1), uint256(1), uint256(0), "x"))
        );
        assertFalse(ok);
        assertEq(address(c).balance, 0);
    }

    // ------------------------------------------------------------------ hide via HiddenList

    function test_HiddenListTakesCommentAsKind3() public {
        MockNFT nft = new MockNFT();
        HiddenList list = new HiddenList(address(0x7EA5), address(nft), address(0));
        uint256 id = c.post(VAULT, 1, 1, 0, "nasty");
        uint256[] memory one = new uint256[](1);
        for (uint256 i; i < 10; ++i) {
            address w = address(uint160(0x1000 + i));
            nft.mint(w, i + 1);
            one[0] = i + 1;
            vm.prank(w);
            list.vote(address(c), 3, id, true, one);
        }
        vm.warp(block.timestamp + 24 hours);
        (uint8 state,,,,) = list.status(address(c), 3, id);
        assertEq(state, list.HIDDEN_BY_VOTE());
        // the wallet's setState path too
        HiddenList.Item[] memory items = new HiddenList.Item[](1);
        items[0] = HiddenList.Item(address(c), 3, id + 1);
        vm.prank(address(0x7EA5));
        list.setState(items, 1);
        (state,,,,) = list.status(address(c), 3, id + 1);
        assertEq(state, 1);
    }

    // ------------------------------------------------------------------ gas

    function _gasTop(uint256 n) internal returns (uint256 g) {
        string memory t = _text(n);
        uint256 before = gasleft();
        c.post(VAULT, 1, 3, 0, t);
        g = before - gasleft();
    }

    function test_GasReport() public {
        c.post(VAULT, 1, 1, 0, "warm the counter");
        uint256 g100 = _gasTop(100);
        uint256 g280 = _gasTop(280);
        uint256 g500 = _gasTop(500);
        string memory t = _text(280);
        uint256 before = gasleft();
        c.post(VAULT, 1, 3, 2, t);
        uint256 gReply = before - gasleft();
        console2.log("exec gas post 100B", g100);
        console2.log("exec gas post 280B", g280);
        console2.log("exec gas post 500B", g500);
        console2.log("exec gas reply 280B", gReply);
        assertLt(g500, 80_000);
    }
}
