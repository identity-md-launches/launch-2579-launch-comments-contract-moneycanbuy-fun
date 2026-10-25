# Launch text for the IMD swarm: DareComments

`src/DareComments.sol`, the comments under tasks and proofs, is its own `evm_contracts` launch: one contract with no
constructor arguments, deployed in one transaction through the IMD ProjectFactory (`0xfF03…7120`), 0.5 IMD. It reads
no other contract and no other contract reads it, so it needs no address from another launch. Runtime
932 bytes (`forge build --sizes`). Its tests: `test/DareComments.t.sol` (19 tests), `forge test` runs 709.

## Launch text (`evm_contracts`, DareComments)

```
Launch the comments contract of moneycanbuy.fun as it is: DareComments, an evm_contracts launch from this repository on Ethereum mainnet (no token), one contract. It stands alone: it reads no other contract and no other contract reads it.

Contracts, in this order:
1. DareComments, constructorArgs []

DareComments keeps the comments under the tasks and proofs of moneycanbuy.fun as events. post(vault, kind, targetId, parentId, text): kind 1 a task, 2 a proof, any other kind reverts BadKind; text is 1..500 bytes of UTF-8, otherwise BadText; parentId 0 is a top-level comment, otherwise it must be the id of a comment of the same (vault, kind, targetId), otherwise BadParent. Ids are global and start at 1; count is the last id handed out. Every post emits Comment(uint256 indexed id, address indexed vault, uint256 indexed targetId, uint8 kind, uint256 parentId, address author, string text, uint256 prevBlock) with author = msg.sender and prevBlock = the block of the previous comment of the same (vault, kind, targetId), 0 for its first. lastBlock(vault, kind, targetId) returns the block of the newest comment of that thread, 0 when it has none. A reader without an archive node walks back from lastBlock along prevBlock with getLogs of single blocks. Hiding a comment is not part of this contract: the site's hide list HiddenList, already deployed, takes (the DareComments address, 3, id) like any other item.

Fixed parameters, fail, don't change: no constructor arguments; kinds 1 and 2 only; at most 500 bytes of text and at least 1; ids from 1; the functions post(address,uint8,uint256,uint256,string) returning the new id, lastBlock(address,uint8,uint256), count(), KIND_TASK() = 1, KIND_PROOF() = 2, MAX_TEXT() = 500; the event Comment with exactly the fields above, in that order, the first three indexed; the errors BadKind(), BadText(), BadParent(). The site decodes exactly these; if a reproduced finding would need any of them changed, fail the job instead of changing it.

DareComments has no owner, no admin, no role, no pause and no upgrade path; no payable function, no receive or fallback, no token call and no external call; it holds no money. The constructor is empty.

Known limitations (accepted rules, not findings): anyone may post, gas is the only cost and there is no rate limit; vault and targetId are not checked against any contract (the site shows only items that exist); the text is any UTF-8 and is not filtered (the site renders it as plain text and hides through HiddenList); a reply may answer a reply, depth is unlimited; count and lastBlock only grow, nothing is ever deleted.

The tests must keep passing: forge test (709 tests), of them 19 in test/DareComments.t.sol for this contract.

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Do not change the fixed parameters above, and do not add an owner, a pause, an upgrade path, a fee, a payable function or a token call.
Known limitations listed in docs are accepted rules, not findings; do not change them.
```

## Known limitations

- Anyone may post; gas is the only cost and there is no rate limit.
- `vault` and `targetId` are not checked against any contract; the site shows only items that exist.
- The text is any UTF-8 of 1 to 500 bytes and is not filtered; the site renders it as plain text and hides a comment
  through `HiddenList` with the key (the DareComments address, 3, id).
- A reply may answer a reply; depth is unlimited, a reply's parent must be in the same thread.
- `count` and `lastBlock` only grow; nothing is ever deleted.
