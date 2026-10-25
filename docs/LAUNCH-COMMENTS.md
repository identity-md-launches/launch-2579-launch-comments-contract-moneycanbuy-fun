# Launch text for the IMD swarm: DareComments

`src/DareComments.sol`, the comments under tasks and proofs, is its own `evm_contracts` launch: one contract with no
constructor arguments, deployed in one transaction through the IMD ProjectFactory (`0xfF03…7120`), 0.5 IMD. It reads
no other contract and no other contract reads it, so it needs no address from another launch. Runtime
932 bytes (`forge build --sizes`). Its tests: `test/DareComments.t.sol` (19 original tests) and
`test/review/DareCommentsLaunch.t.sol` (8 launch and reader regression tests). Validation results are in
[`ADAPTATION.md`](../ADAPTATION.md); the quoted launch request below retains the original 709-test baseline.

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

## Reading a thread from events

For a thread `(vault, kind, targetId)`, start at `lastBlock(vault, kind, targetId)`. Zero means there are no
comments. For each nonzero block `b`:

1. Request `eth_getLogs` with `address` set to the deployed DareComments address, `fromBlock = toBlock = b`, and
   topics `[Comment signature, null, vault, targetId]`. Encode `vault` and `targetId` as 32-byte topics; the
   signature is `keccak256("Comment(uint256,address,uint256,uint8,uint256,address,string,uint256)")`.
2. Decode the event data `(kind, parentId, author, text, prevBlock)` and keep only events with the requested
   `kind`. Kind is **not indexed**: a task and a proof with the same vault and target id match the same topics.
3. Collect all matching comments in the block. Take the **minimum `prevBlock` among those matching events**
   (equivalently, the `prevBlock` of the earliest matching event in log order) as the next block. It is less
   than `b`, or zero when this is the thread's first block. Later comments in the same block have
   `prevBlock == b`; following the last event would repeat the same block forever.
4. Continue until the next block is zero. If a referenced block has no matching events, handle that as an
   incomplete or inconsistent read rather than silently treating the thread as finished.

For example, task 5 has a comment at block 10. At block 20, proof 5 gets its first comment and task 5 gets a
reply. The block-20 topic query returns both: the proof's `prevBlock` is 0, while the task's is 10. Filter kind
first so that the task reader continues to block 10. Similarly, two comments in a new thread at block 7 have
`prevBlock` values 0 and 7; collect both, then stop at 0.

Apply the site's HiddenList display decision after collecting the thread links: a hidden comment still
participates in its thread's history. The key remains `(DareComments address, 3, comment id)`.

These reader cases and deployment through a factory are covered by `test/review/DareCommentsLaunch.t.sol`.
