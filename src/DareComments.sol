// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title DareComments
/// @notice Comments under tasks and proofs, written to the chain as events. Standalone: no core contract reads it and
///         it reads no core contract, so a comment may name any `targetId` (the site shows only the ones that exist).
///         It holds no money (no `payable`, no `receive`, no token call), has no owner, no role, no upgrade.
///         Key of a thread: `(vault, kind, targetId)`, kind 1 = task, 2 = proof (a dispute lives on its proof).
///         Comment ids are global, from 1. A reply names its parent's id, which must be in the same thread.
///         Hiding is not here: the site's HiddenList takes `(address(this), 3, id)` like any other item.
///         Reading without an archive node: `lastBlock(vault, kind, targetId)` is the block of a thread's newest
///         comment and each event names `prevBlock`, the block of the thread's comment before it (0 for the first),
///         so a reader asks getLogs for single blocks along that chain instead of scanning from the deployment.
contract DareComments {
    uint8 public constant KIND_TASK = 1;
    uint8 public constant KIND_PROOF = 2;
    uint256 public constant MAX_TEXT = 500;

    /// @notice Ids handed out so far; the next comment gets `count + 1`.
    uint256 public count;

    /// @dev id => keccak256(vault, kind, targetId) of its thread; only for checking a reply's parent.
    mapping(uint256 => bytes32) private _thread;

    /// @dev keccak256(vault, kind, targetId) => block of the thread's newest comment, 0 = none yet.
    mapping(bytes32 => uint256) private _last;

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

    error BadKind();
    error BadText();
    error BadParent();

    /// @notice Posts `text` (UTF-8, 1..500 bytes) under item `targetId` of `vault`; `parentId` 0 = top level,
    ///         else the id of a comment of the same `(vault, kind, targetId)`. Returns the new comment's id.
    function post(address vault, uint8 kind, uint256 targetId, uint256 parentId, string calldata text)
        external
        returns (uint256 id)
    {
        if (kind != KIND_TASK && kind != KIND_PROOF) revert BadKind();
        uint256 len = bytes(text).length;
        if (len == 0 || len > MAX_TEXT) revert BadText();
        bytes32 t = keccak256(abi.encode(vault, kind, targetId));
        if (parentId != 0 && _thread[parentId] != t) revert BadParent();
        id = ++count;
        _thread[id] = t;
        uint256 prev = _last[t];
        _last[t] = block.number;
        emit Comment(id, vault, targetId, kind, parentId, msg.sender, text, prev);
    }

    /// @notice Block of the newest comment of thread `(vault, kind, targetId)`, 0 when it has none.
    function lastBlock(address vault, uint8 kind, uint256 targetId) external view returns (uint256) {
        return _last[keccak256(abi.encode(vault, kind, targetId))];
    }
}
