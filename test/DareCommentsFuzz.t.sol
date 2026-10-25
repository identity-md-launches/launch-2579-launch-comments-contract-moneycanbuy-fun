// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DareComments} from "../src/DareComments.sol";

/// @dev Posts from a contract: the author is that contract (msg.sender), not the transaction's origin.
contract CommentsRelay {
    function post(DareComments c, address vault, uint8 kind, uint256 targetId, uint256 parentId, string memory text)
        external
        returns (uint256)
    {
        return c.post(vault, kind, targetId, parentId, text);
    }
}

/// @dev Stateless fuzz over each rule of post, plus the edges the 19 base tests do not pin: every text length
///      around the bounds, every uint8 kind, any parent id, any author, dirty ABI words, the order the checks run
///      in, and that a rejected post leaves count, lastBlock and the logs untouched.
contract DareCommentsFuzzTest is Test {
    DareComments c;

    address constant VAULT = address(0xBA07);

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

    // ------------------------------------------------------------------ text length

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TextLengthBounds(uint256 len) public {
        len = bound(len, 0, 1200);
        string memory text = _text(len);
        if (len == 0 || len > 500) {
            vm.expectRevert(DareComments.BadText.selector);
            c.post(VAULT, 1, 1, 0, text);
            assertEq(c.count(), 0);
            assertEq(c.lastBlock(VAULT, 1, 1), 0);
        } else {
            assertEq(c.post(VAULT, 1, 1, 0, text), 1);
            assertEq(c.count(), 1);
        }
    }

    function test_TextBoundaryEachSide() public {
        uint256[6] memory ok = [uint256(1), 2, 250, 498, 499, 500];
        for (uint256 i; i < ok.length; ++i) {
            assertEq(c.post(VAULT, 2, 4, 0, _text(ok[i])), i + 1);
        }
        uint256[4] memory bad = [uint256(0), 501, 502, 4096];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(DareComments.BadText.selector);
            c.post(VAULT, 2, 4, 0, _text(bad[i]));
        }
        assertEq(c.count(), ok.length);
    }

    function test_TextIsKeptVerbatim() public {
        // NUL bytes, newlines, markup and 4-byte UTF-8: the event carries exactly what was posted
        string memory text = unicode"a\u0000b\n<script>alert(1)</script> 🐸";
        vm.recordLogs();
        c.post(VAULT, 1, 1, 0, text);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,, string memory got,) = abi.decode(logs[0].data, (uint8, uint256, address, string, uint256));
        assertEq(keccak256(bytes(got)), keccak256(bytes(text)));
    }

    // ------------------------------------------------------------------ kind

    function testFuzz_KindOnlyOneOrTwo(uint8 kind) public {
        if (kind == 1 || kind == 2) {
            assertEq(c.post(VAULT, kind, 1, 0, "x"), 1);
            assertEq(c.lastBlock(VAULT, kind, 1), block.number);
        } else {
            vm.expectRevert(DareComments.BadKind.selector);
            c.post(VAULT, kind, 1, 0, "x");
            assertEq(c.count(), 0);
            assertEq(c.lastBlock(VAULT, kind, 1), 0);
        }
    }

    function test_ConstantsAreFixed() public view {
        assertEq(c.KIND_TASK(), 1);
        assertEq(c.KIND_PROOF(), 2);
        assertEq(c.MAX_TEXT(), 500);
        assertEq(c.count(), 0);
    }

    /// @dev Kind is checked first, then text, then parent: a post wrong in several ways reports the first.
    function test_CheckOrder() public {
        vm.expectRevert(DareComments.BadKind.selector);
        c.post(VAULT, 0, 1, 99, "");
        vm.expectRevert(DareComments.BadKind.selector);
        c.post(VAULT, 9, 1, 0, _text(501));
        vm.expectRevert(DareComments.BadText.selector);
        c.post(VAULT, 1, 1, 99, "");
        vm.expectRevert(DareComments.BadText.selector);
        c.post(VAULT, 2, 1, 99, _text(501));
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT, 2, 1, 99, "x");
    }

    // ------------------------------------------------------------------ parent

    /// @dev Three threads with comments; any parent id is accepted exactly when it names one of the thread's own.
    function testFuzz_AnyParentId(uint256 parentId, uint256 pick) public {
        // ids 1,4 thread A (task 5); 2,5 thread B (proof 5); 3 thread C (task 5 of another vault)
        c.post(VAULT, 1, 5, 0, "a");
        c.post(VAULT, 2, 5, 0, "b");
        c.post(address(0xBA08), 1, 5, 0, "c");
        c.post(VAULT, 1, 5, 1, "a reply");
        c.post(VAULT, 2, 5, 2, "b reply");
        if (pick % 2 == 0) parentId = bound(parentId, 0, 8);
        uint8 kind = pick % 3 == 0 ? 2 : 1;
        bool ok = parentId == 0 || (kind == 1 ? (parentId == 1 || parentId == 4) : (parentId == 2 || parentId == 5));
        if (ok) {
            assertEq(c.post(VAULT, kind, 5, parentId, "reply"), 6);
        } else {
            vm.expectRevert(DareComments.BadParent.selector);
            c.post(VAULT, kind, 5, parentId, "reply");
            assertEq(c.count(), 5);
        }
    }

    function test_CannotReplyToItsOwnId() public {
        // the new id is count + 1, which has no thread until the post succeeds
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT, 1, 5, 1, "self");
        c.post(VAULT, 1, 5, 0, "root");
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT, 1, 5, 2, "self");
        assertEq(c.post(VAULT, 1, 5, 1, "reply"), 2);
    }

    function test_ReplyToRevertedIdReverts() public {
        // a rejected post hands out no id, so its would-be id is never a parent
        vm.expectRevert(DareComments.BadText.selector);
        c.post(VAULT, 1, 5, 0, "");
        vm.expectRevert(DareComments.BadParent.selector);
        c.post(VAULT, 1, 5, 1, "x");
    }

    function test_DeepReplyChain() public {
        uint256 parent;
        for (uint256 i; i < 40; ++i) {
            parent = c.post(VAULT, 2, 7, parent, "deeper");
            assertEq(parent, i + 1);
        }
        assertEq(c.count(), 40);
    }

    // ------------------------------------------------------------------ author and ids

    function testFuzz_AuthorIsMsgSender(address author, address origin) public {
        vm.prank(author, origin);
        vm.recordLogs();
        c.post(VAULT, 1, 1, 0, "x");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,, address got,,) = abi.decode(logs[0].data, (uint8, uint256, address, string, uint256));
        assertEq(got, author);
    }

    function test_ContractAuthorIsTheContract() public {
        CommentsRelay relay = new CommentsRelay();
        vm.recordLogs();
        vm.prank(address(0xE0A), address(0xE0A));
        relay.post(c, VAULT, 1, 1, 0, "from a wallet contract");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,, address got,,) = abi.decode(logs[0].data, (uint8, uint256, address, string, uint256));
        assertEq(got, address(relay));
    }

    /// @dev Ids are global across vaults, kinds, targets and authors, and count is the last one.
    function testFuzz_IdsGlobalAndSequential(uint256 seed) public {
        uint256 n = bound(seed, 1, 30);
        for (uint256 i; i < n; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, i)));
            vm.prank(address(uint160(s)));
            uint256 id = c.post(address(uint160(s >> 160)), uint8(1 + (s % 2)), s >> 8, 0, "x");
            assertEq(id, i + 1);
            assertEq(c.count(), id);
        }
    }

    // ------------------------------------------------------------------ threads

    /// @dev Two different (vault, kind, targetId) never share lastBlock.
    function testFuzz_ThreadsAreSeparate(address v1, uint256 t1, address v2, uint256 t2, bool proof2) public {
        uint8 k2 = proof2 ? 2 : 1;
        vm.assume(v1 != v2 || t1 != t2 || k2 != 1);
        vm.roll(50);
        c.post(v1, 1, t1, 0, "first");
        assertEq(c.lastBlock(v2, k2, t2), 0);
        vm.roll(60);
        c.post(v2, k2, t2, 0, "second");
        assertEq(c.lastBlock(v1, 1, t1), 50);
        assertEq(c.lastBlock(v2, k2, t2), 60);
    }

    function testFuzz_LastBlockFollowsBlockNumber(uint256 b1, uint256 b2) public {
        b1 = bound(b1, 1, type(uint64).max);
        b2 = bound(b2, b1, type(uint64).max);
        vm.roll(b1);
        c.post(VAULT, 1, 1, 0, "x");
        vm.roll(b2);
        vm.expectEmit(true, true, true, true, address(c));
        emit DareComments.Comment(2, VAULT, 1, 1, 1, address(this), "y", b1);
        c.post(VAULT, 1, 1, 1, "y");
        assertEq(c.lastBlock(VAULT, 1, 1), b2);
    }

    // ------------------------------------------------------------------ rejected posts change nothing

    function testFuzz_RejectedPostChangesNothing(uint8 kind, uint256 len, uint256 parentId) public {
        len = bound(len, 0, 600);
        vm.roll(10);
        c.post(VAULT, 1, 5, 0, "root");
        bool good =
            (kind == 1 || kind == 2) && len >= 1 && len <= 500 && (parentId == 0 || (parentId == 1 && kind == 1));
        vm.roll(20);
        vm.recordLogs();
        (bool ok,) = address(c).call(abi.encodeCall(DareComments.post, (VAULT, kind, 5, parentId, _text(len))));
        assertEq(ok, good);
        if (!ok) {
            assertEq(vm.getRecordedLogs().length, 0);
            assertEq(c.count(), 1);
            assertEq(c.lastBlock(VAULT, 1, 5), 10);
            assertEq(c.lastBlock(VAULT, 2, 5), 0);
        } else {
            assertEq(c.count(), 2);
            assertEq(c.lastBlock(VAULT, kind, 5), 20);
        }
    }

    // ------------------------------------------------------------------ ABI words

    function testFuzz_DirtyVaultWordReverts(uint256 high) public {
        high = bound(high, 1, type(uint96).max);
        bytes memory data = abi.encodeWithSelector(
            DareComments.post.selector, (high << 160) | uint160(VAULT), uint256(1), uint256(1), uint256(0), "x"
        );
        (bool ok,) = address(c).call(data);
        assertFalse(ok);
        assertEq(c.count(), 0);
    }

    function testFuzz_DirtyKindWordReverts(uint256 word) public {
        word = bound(word, 256, type(uint256).max);
        bytes memory data = abi.encodeWithSelector(DareComments.post.selector, VAULT, word, uint256(1), uint256(0), "x");
        (bool ok,) = address(c).call(data);
        assertFalse(ok);
        assertEq(c.count(), 0);
        assertEq(c.lastBlock(VAULT, uint8(word), 1), 0);
    }

    function test_TruncatedOrBadOffsetCalldataReverts() public {
        bytes memory good = abi.encodeCall(DareComments.post, (VAULT, uint8(1), uint256(1), uint256(0), "hello"));
        // cut the text short
        bytes memory cut = new bytes(good.length - 40);
        for (uint256 i; i < cut.length; ++i) {
            cut[i] = good[i];
        }
        (bool ok,) = address(c).call(cut);
        assertFalse(ok);
        // text offset far outside the calldata
        bytes memory bad = abi.encodePacked(
            DareComments.post.selector, abi.encode(VAULT, uint256(1), uint256(1), uint256(0), uint256(1 << 64))
        );
        (ok,) = address(c).call(bad);
        assertFalse(ok);
        // text length word larger than the calldata holds
        bytes memory longLen = abi.encodePacked(
            DareComments.post.selector,
            abi.encode(VAULT, uint256(1), uint256(1), uint256(0), uint256(0xa0), uint256(400)),
            bytes32("short")
        );
        (ok,) = address(c).call(longLen);
        assertFalse(ok);
        assertEq(c.count(), 0);
        (ok,) = address(c).call(good);
        assertTrue(ok);
        assertEq(c.count(), 1);
    }

    function test_ViewsNeedNoState() public view {
        assertEq(c.lastBlock(address(0), 0, 0), 0);
        assertEq(c.lastBlock(address(type(uint160).max), 255, type(uint256).max), 0);
    }
}
