// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DareComments} from "../src/DareComments.sol";

/// @dev Drives DareComments with random posts (valid and invalid kinds, text lengths and parents) from several
///      authors across a few vaults and targets, over rising and repeated blocks. It keeps its own model of what
///      the brief says must happen, and checks every call's outcome, revert reason and event against it.
contract DareCommentsHandler is Test {
    bytes32 constant COMMENT_TOPIC = keccak256("Comment(uint256,address,uint256,uint8,uint256,address,string,uint256)");

    DareComments public immutable c;

    struct Posted {
        address vault;
        uint8 kind;
        uint256 targetId;
        uint256 blockNumber;
        uint256 prevBlock;
    }

    /// @dev ghost: every accepted comment, index = id - 1
    Posted[] public posted;
    /// @dev ghost: thread key => block of its newest comment
    mapping(bytes32 => uint256) public ghostLast;
    /// @dev counts of what the handler saw
    uint256 public accepted;
    uint256 public rejected;
    uint256 public mismatches;
    string public lastMismatch;

    address[3] internal vaults = [address(0xBA07), address(0xBA08), address(0)];
    address[4] internal authors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xD0D0)];

    constructor(DareComments c_) {
        c = c_;
        vm.roll(1000);
    }

    function threadKey(address vault, uint8 kind, uint256 targetId) public pure returns (bytes32) {
        return keccak256(abi.encode(vault, kind, targetId));
    }

    function postedCount() external view returns (uint256) {
        return posted.length;
    }

    function vaultAt(uint256 i) external view returns (address) {
        return vaults[i];
    }

    function _mismatch(string memory why) internal {
        ++mismatches;
        lastMismatch = why;
    }

    function _text(uint256 n, uint256 seed) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = bytes1(uint8(32 + (uint256(keccak256(abi.encode(seed, i))) % 95)));
        }
        return string(b);
    }

    /// @param kindSeed mostly 1 or 2, sometimes any uint8
    /// @param lenSeed mostly 1..500, sometimes 0 or 501..700
    /// @param parentSeed 0, an existing id (same or other thread), or a future / random id
    function post(
        uint256 actorSeed,
        uint256 vaultSeed,
        uint256 kindSeed,
        uint256 targetSeed,
        uint256 parentSeed,
        uint256 lenSeed,
        uint256 blockStep
    ) external {
        address author = authors[actorSeed % authors.length];
        address vault = vaults[vaultSeed % vaults.length];
        uint8 kind = kindSeed % 8 == 0 ? uint8(kindSeed >> 8) : uint8(1 + (kindSeed % 2));
        uint256 targetId = targetSeed % 4 == 3 ? type(uint256).max : targetSeed % 3;
        uint256 len;
        uint256 lenMode = lenSeed % 10;
        if (lenMode == 0) len = 0;
        else if (lenMode == 1) len = bound(lenSeed >> 8, 501, 700);
        else if (lenMode == 2) len = 500;
        else len = bound(lenSeed >> 8, 1, 500);

        uint256 parentId;
        uint256 parentMode = parentSeed % 4;
        if (parentMode == 1 && posted.length != 0) parentId = 1 + ((parentSeed >> 8) % posted.length);
        else if (parentMode == 2) parentId = posted.length + 1 + ((parentSeed >> 8) % 3);
        else if (parentMode == 3) parentId = parentSeed >> 8;

        vm.roll(block.number + (blockStep % 3)); // 0 = same block as the call before

        // what the brief says must happen, checked in its order
        bytes32 t = threadKey(vault, kind, targetId);
        bytes4 expected;
        if (kind != 1 && kind != 2) {
            expected = DareComments.BadKind.selector;
        } else if (len == 0 || len > 500) {
            expected = DareComments.BadText.selector;
        } else if (parentId != 0) {
            bool ok = parentId <= posted.length;
            if (ok) {
                Posted storage p = posted[parentId - 1];
                ok = p.vault == vault && p.kind == kind && p.targetId == targetId;
            }
            if (!ok) expected = DareComments.BadParent.selector;
        }

        string memory text = _text(len, parentSeed ^ lenSeed);
        uint256 countBefore = c.count();
        vm.recordLogs();
        vm.prank(author);
        try c.post(vault, kind, targetId, parentId, text) returns (uint256 id) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (expected != bytes4(0)) return _mismatch("accepted a post the brief rejects");
            if (id != posted.length + 1) return _mismatch("id is not the next global id");
            if (c.count() != id) return _mismatch("count is not the last id");
            if (logs.length != 1) return _mismatch("not exactly one event");
            Vm.Log memory l = logs[0];
            if (l.emitter != address(c) || l.topics.length != 4 || l.topics[0] != COMMENT_TOPIC) {
                return _mismatch("event signature");
            }
            if (
                l.topics[1] != bytes32(id) || l.topics[2] != bytes32(uint256(uint160(vault)))
                    || l.topics[3] != bytes32(targetId)
            ) return _mismatch("event topics");
            uint256 prev = ghostLast[t];
            if (keccak256(l.data) != keccak256(abi.encode(kind, parentId, author, text, prev))) {
                return _mismatch("event data");
            }
            posted.push(Posted(vault, kind, targetId, block.number, prev));
            ghostLast[t] = block.number;
            ++accepted;
        } catch (bytes memory reason) {
            if (vm.getRecordedLogs().length != 0) return _mismatch("event from a reverted post");
            if (expected == bytes4(0)) return _mismatch("rejected a valid post");
            if (keccak256(reason) != keccak256(abi.encodeWithSelector(expected))) return _mismatch("wrong error");
            if (c.count() != countBefore) return _mismatch("count moved on revert");
            ++rejected;
        }
    }

    /// @dev Sends ETH at the contract: plain, with post calldata, and with unknown calldata. Every one must fail.
    function sendEth(uint256 amount, uint256 mode) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(address(this), amount);
        bytes memory data;
        if (mode % 3 == 1) {
            data = abi.encodeCall(DareComments.post, (vaults[0], uint8(1), uint256(0), uint256(0), "x"));
        } else if (mode % 3 == 2) {
            data = hex"deadbeef";
        }
        uint256 countBefore = c.count();
        (bool ok,) = address(c).call{value: amount}(data);
        if (ok) _mismatch("accepted ETH");
        if (c.count() != countBefore) _mismatch("count moved on an ETH call");
    }
}

/// @dev DareComments holds no value; the invariants are over its two pieces of state, `count` and `lastBlock`, and
///      the event chain readers walk: after any sequence ids are 1..count, every thread's lastBlock is the block
///      of its newest accepted comment, and walking a thread back from lastBlock along prevBlock visits every one
///      of its comments and ends at 0.
contract DareCommentsInvariantTest is Test {
    DareComments c;
    DareCommentsHandler h;

    function setUp() public {
        c = new DareComments();
        h = new DareCommentsHandler(c);
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_HandlerSawNoMismatch() public view {
        assertEq(h.mismatches(), 0, h.lastMismatch());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_CountIsAcceptedPosts() public view {
        assertEq(c.count(), h.postedCount());
        assertEq(c.count(), h.accepted());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_NoBalance() public view {
        assertEq(address(c).balance, 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_LastBlockMatchesNewestComment() public view {
        for (uint256 v; v < 3; ++v) {
            address vault = h.vaultAt(v);
            for (uint8 kind; kind <= 3; ++kind) {
                for (uint256 t; t < 4; ++t) {
                    uint256 targetId = t == 3 ? type(uint256).max : t;
                    uint256 want = h.ghostLast(h.threadKey(vault, kind, targetId));
                    assertEq(c.lastBlock(vault, kind, targetId), want);
                    if (kind == 0 || kind == 3) assertEq(want, 0);
                }
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_PrevBlockChainVisitsEveryComment() public view {
        uint256 n = h.postedCount();
        uint256 visited;
        for (uint256 v; v < 3; ++v) {
            for (uint8 kind = 1; kind <= 2; ++kind) {
                for (uint256 t; t < 4; ++t) {
                    visited += _walk(h.vaultAt(v), kind, t == 3 ? type(uint256).max : t, n);
                }
            }
        }
        assertEq(visited, n, "the walk missed or repeated comments");
    }

    /// @dev Reader without an archive: ask for single blocks starting at lastBlock; in each, take the thread's
    ///      comments and continue at the smallest prevBlock among them, which must be strictly older.
    function _walk(address vault, uint8 kind, uint256 targetId, uint256 n) internal view returns (uint256 found) {
        uint256 b = c.lastBlock(vault, kind, targetId);
        while (b != 0) {
            uint256 next = type(uint256).max;
            uint256 inBlock;
            for (uint256 i; i < n; ++i) {
                (address pv, uint8 pk, uint256 pt, uint256 pb, uint256 pp) = h.posted(i);
                if (pb != b || pv != vault || pk != kind || pt != targetId) continue;
                ++inBlock;
                if (pp < next) next = pp;
            }
            assertGt(inBlock, 0, "lastBlock/prevBlock names a block without a comment of the thread");
            assertLt(next, b, "prevBlock does not go back");
            found += inBlock;
            b = next;
        }
    }
}
