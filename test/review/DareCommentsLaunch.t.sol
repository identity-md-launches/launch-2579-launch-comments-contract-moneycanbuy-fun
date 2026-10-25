// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DareComments} from "../../src/DareComments.sol";

/// @dev Local factory rehearsal: raw creation code, no arguments, zero ETH, no initialization call.
contract CommentsFactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "deployment failed");
    }
}

contract DareCommentsLaunchTest is Test {
    bytes32 constant COMMENT_TOPIC = keccak256("Comment(uint256,address,uint256,uint8,uint256,address,string,uint256)");

    DareComments comments;
    address vault;

    function setUp() public {
        comments = new DareComments();
        vault = makeAddr("comments vault");
    }

    function test_FactoryDeploymentNeedsNoArgumentsOrSetup() public {
        vm.chainId(1);
        assertEq(DareComments.post.selector, bytes4(keccak256("post(address,uint8,uint256,uint256,string)")));
        assertEq(DareComments.lastBlock.selector, bytes4(keccak256("lastBlock(address,uint8,uint256)")));
        assertEq(DareComments.BadKind.selector, bytes4(keccak256("BadKind()")));
        assertEq(DareComments.BadText.selector, bytes4(keccak256("BadText()")));
        assertEq(DareComments.BadParent.selector, bytes4(keccak256("BadParent()")));
        CommentsFactoryProbe factory = new CommentsFactoryProbe();
        bytes memory code = type(DareComments).creationCode;
        bytes32 salt = keccak256("DareComments launch rehearsal");
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );
        assertEq(predicted.code.length, 0);
        assertLe(code.length, 49_152);

        DareComments deployed = DareComments(factory.deploy(code, salt));
        assertEq(address(deployed), predicted);
        assertGt(address(deployed).code.length, 0);
        assertLe(address(deployed).code.length, 24_576);
        assertEq(address(deployed).code, type(DareComments).runtimeCode);
        assertEq(deployed.count(), 0);
        assertEq(deployed.lastBlock(vault, 1, 5), 0);
        assertEq(deployed.KIND_TASK(), 1);
        assertEq(deployed.KIND_PROOF(), 2);
        assertEq(deployed.MAX_TEXT(), 500);

        // The first outside caller can post immediately; the deploying factory acquires no role.
        address writer = makeAddr("first comments writer");
        vm.roll(7);
        vm.recordLogs();
        vm.prank(writer);
        uint256 id = deployed.post(vault, 1, 5, 0, "first");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(id, 1);
        assertEq(deployed.count(), 1);
        assertEq(deployed.lastBlock(vault, 1, 5), 7);
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 4);
        assertEq(logs[0].topics[0], COMMENT_TOPIC);
        assertEq(logs[0].topics[1], bytes32(id));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(vault))));
        assertEq(logs[0].topics[3], bytes32(uint256(5)));
        assertEq(logs[0].data, abi.encode(uint8(1), uint256(0), writer, "first", uint256(0)));
    }

    function test_DeploymentRejectsEth() public {
        bytes memory code = type(DareComments).creationCode;
        vm.deal(address(this), 1);
        address deployed;
        assembly ("memory-safe") {
            deployed := create(1, add(code, 32), mload(code))
        }
        assertEq(deployed, address(0));
        assertEq(address(this).balance, 1);
    }

    function test_RuntimeHasNoCallsOrForbiddenOpcodes() public view {
        bytes memory code = address(comments).code;
        // Match the supplied floor's PUSH-data and basic-block handling. Also reject external
        // reads/calls and contract creation, which this standalone application does not need.
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden launch opcode");
                assertTrue(op != 0xf1 && op != 0xfa, "external call");
                assertTrue(op != 0xf0 && op != 0xf5, "contract creation");
            }
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }

    function test_UnknownSelectorsAndEmptyCalldataRevert() public {
        (bool ok,) = address(comments).call("");
        assertFalse(ok);
        (ok,) = address(comments).call(hex"deadbeef");
        assertFalse(ok);
        (ok,) = address(comments).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(comments).call(abi.encodeWithSignature("initialize()"));
        assertFalse(ok);
        assertEq(comments.count(), 0);
    }

    function test_InvalidKindsAndParentsDoNotChangeState() public {
        vm.roll(10);
        comments.post(vault, 1, 5, 0, "root");
        vm.roll(20);
        vm.recordLogs();
        for (uint256 kind; kind <= type(uint8).max; ++kind) {
            if (kind == 1 || kind == 2) continue;
            vm.expectRevert(DareComments.BadKind.selector);
            comments.post(vault, uint8(kind), 5, 0, "invalid kind");
        }
        vm.expectRevert(DareComments.BadParent.selector);
        comments.post(vault, 1, 5, 2, "self or future parent");
        vm.expectRevert(DareComments.BadParent.selector);
        comments.post(vault, 1, 5, type(uint256).max, "nonexistent parent");
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(comments.count(), 1);
        assertEq(comments.lastBlock(vault, 1, 5), 10);
        assertEq(comments.lastBlock(vault, 2, 5), 0);
        assertEq(comments.post(vault, 1, 5, 1, "valid reply"), 2);
    }

    function test_NonCanonicalKindCalldataReverts() public {
        // A raw uint256 value of 257 must not be truncated to the otherwise-valid task kind 1.
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("post(address,uint8,uint256,uint256,string)")),
            vault,
            uint256(257),
            uint256(5),
            uint256(0),
            "invalid encoding"
        );
        (bool ok,) = address(comments).call(data);
        assertFalse(ok);
        assertEq(comments.count(), 0);
        assertEq(comments.lastBlock(vault, 1, 5), 0);
    }

    function test_SameBlockReaderUsesEarliestThreadEvent() public {
        vm.roll(7);
        vm.recordLogs();
        uint256 root = comments.post(vault, 2, 3, 0, "a");
        comments.post(vault, 2, 3, root, "b");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(comments.lastBlock(vault, 2, 3), 7);
        (, uint256 firstPrev) = _kindAndPrev(logs[0]);
        (, uint256 secondPrev) = _kindAndPrev(logs[1]);
        assertEq(firstPrev, 0);
        assertEq(secondPrev, 7); // Following the last event would request this block forever.

        (uint256 found, uint256 next) = _readThreadBlock(logs, 2, 3);
        assertEq(found, 2);
        assertEq(next, 0);
        assertLt(next, 7);
    }

    function test_ReaderFiltersKindBeforeChoosingPreviousBlock() public {
        vm.roll(10);
        vm.recordLogs();
        uint256 root = comments.post(vault, 1, 5, 0, "task");
        Vm.Log[] memory block10 = vm.getRecordedLogs();

        vm.roll(20);
        vm.recordLogs();
        comments.post(vault, 2, 5, 0, "proof");
        comments.post(vault, 1, 5, root, "task reply");
        Vm.Log[] memory block20 = vm.getRecordedLogs();
        assertEq(block20.length, 2);
        assertEq(comments.lastBlock(vault, 1, 5), 20);
        assertEq(comments.lastBlock(vault, 2, 5), 20);

        // Both events match a single-block getLogs request with topics [Comment, null, vault, 5].
        for (uint256 i; i < block20.length; ++i) {
            assertEq(block20[i].emitter, address(comments));
            assertEq(block20[i].topics[0], COMMENT_TOPIC);
            assertEq(block20[i].topics[2], bytes32(uint256(uint160(vault))));
            assertEq(block20[i].topics[3], bytes32(uint256(5)));
        }
        (uint8 proofKind, uint256 proofPrev) = _kindAndPrev(block20[0]);
        (uint8 taskKind, uint256 taskPrev) = _kindAndPrev(block20[1]);
        assertEq(proofKind, 2);
        assertEq(taskKind, 1);
        assertEq(proofPrev, 0); // An unfiltered minimum would stop before the task's root.
        assertEq(taskPrev, 10);

        (uint256 found20, uint256 next) = _readThreadBlock(block20, 1, 5);
        assertEq(found20, 1);
        assertEq(next, 10);
        (uint256 found10, uint256 end) = _readThreadBlock(block10, 1, 5);
        assertEq(found10, 1);
        assertEq(end, 0);
        assertEq(found20 + found10, 2);
    }

    function _kindAndPrev(Vm.Log memory log) private pure returns (uint8 kind, uint256 prev) {
        (kind,,,, prev) = abi.decode(log.data, (uint8, uint256, address, string, uint256));
    }

    /// @dev Model a single-block log query, then filter decoded kind before selecting min(prevBlock).
    function _readThreadBlock(Vm.Log[] memory logs, uint8 kind, uint256 target)
        private
        view
        returns (uint256 found, uint256 next)
    {
        next = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (
                log.emitter != address(comments) || log.topics.length != 4 || log.topics[0] != COMMENT_TOPIC
                    || log.topics[2] != bytes32(uint256(uint160(vault))) || log.topics[3] != bytes32(target)
            ) continue;
            (uint8 eventKind, uint256 prev) = _kindAndPrev(log);
            if (eventKind != kind) continue;
            ++found;
            if (prev < next) next = prev;
        }
        require(found != 0, "thread block missing");
    }
}
