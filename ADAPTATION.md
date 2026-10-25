# DareComments launch adaptation

Launch scope: Ethereum mainnet (chain id 1), `evm_contracts`, one application named `DareComments`,
`constructorArgs: []`, no token. No production contract change is required. `src/DareComments.sol` is unchanged:
its implicit constructor is empty and nonpayable, it has no dependencies or linked libraries, and it is ready
for use immediately after factory deployment. No owner or initialization argument is needed.

## Changes

| File | Change and reason |
| --- | --- |
| `docs/LAUNCH-COMMENTS.md` | Added precise single-block log traversal instructions for the two reproduced informational reader notes and updated the test inventory. Readers filter decoded kind before choosing the minimum previous block and collect all comments in that block. The fixed event and contract behavior are preserved. |
| `test/review/DareCommentsLaunch.t.sol` | Added eight tests covering the supplied audit probes, both reader notes, raw factory deployment with no arguments, rejection of deployment ETH, runtime restrictions, and immediate public posting. These provide repeatable evidence for the launch requirements without changing the existing 19 contract tests. |
| `ADAPTATION.md` | Added this required change record, audit disposition, and validation scope. |

All existing production sources, tests, build configuration, and dependencies are preserved. No manifest,
deployment script, token, privilege, pause, upgrade, fee, or payable application function was added.

## Supplied audit disposition

1. **Scope and coverage; no defect reproduced**
   (`76d3c0503ee1abc88c68f7b1c61579c6becf4d1123fbf4373ad8ac2c35b3e7d1`).
   Reviewed the full contract and its original 19 tests. Its only state-changing entry point is the public
   `post`: it checks kind, text byte length, and parent thread before assigning the next global id, updating
   the thread head, and emitting the event. `lastBlock` hashes the same static tuple. The counter uses checked
   arithmetic; there is no attainable overflow path, external interaction, or inherited behavior.
   The new tests exercise every invalid uint8 kind, self/future and maximum parent ids, malformed kind 257
   calldata, rejected empty/unknown calls, unchanged state on rejection, and the fixed event encoding. No
   contract defect was identified, so no production fix was made.

2. **Same-block previous pointer**
   (`3d0e8cd29b8b527990ed17f4c65549cb85d175dc2f35766567ce3efd55e85eb3`).
   Reproduction: two comments in one new thread at block 7 produce `prevBlock` values 0 and 7, and
   `lastBlock == 7`. Following the second pointer repeats block 7; collecting both and taking the minimum
   stops correctly at 0. This matches the specification, not a contract defect.
   `test_SameBlockReaderUsesEarliestThreadEvent` and the added reader documentation preserve that distinction.

3. **Kind is not an indexed topic**
   (`38e9f4d6968e8c46895c0b8b16fa35802967a0304a5fdfac102752b7014d076e`).
   Reproduction: task 5 at block 10, then proof 5 and a task-5 reply at block 20. Both block-20 events match
   the indexed vault and target topics, but their previous blocks are 0 and 10. An unfiltered minimum loses
   the task root; filtering kind 1 first recovers the chain `20 -> 10 -> 0`.
   `test_ReaderFiltersKindBeforeChoosingPreviousBlock` covers the actual emitted topics and decoded data.
   Documented the reader requirement; the event layout remains unchanged. This is also informational.

All three supplied entries are consistent with the reviewed code; none establishes a contract vulnerability
requiring a behavior change. The reader implementations illustrated by the two mistaken algorithms are not
part of this repository, so no claim is made that the live site's reader was repaired or tested.

## Review and launch coverage

Applied the supplied Trail of Bits entry-point classification and the Pashov, x-ray, and Ethereum security
checklists to this contract. The twelve Pashov specialties were considered in a single review, not independent
agent audits. Boundary, arithmetic, state consistency, identity, event decoding, deployment, and traversal
checks apply. Token economics, oracle, signature, reentrancy callback, governance, and upgrade mechanisms are
absent. HiddenList was inspected only for the `(DareComments address, 3, id)` integration; the rest of the
project is outside this contract audit, but remains covered by its existing test suite.

The factory rehearsal deploys raw creation code through CREATE2 at chain id 1 without configuration or
initialization calls, checks the predicted address and size bounds, and makes the first post from another
caller. The opcode test follows the supplied deployment floor's instruction/data handling and also rejects
CALL, STATICCALL, CREATE, and CREATE2 in the application's runtime. Source inspection and rejected `owner()`
and `initialize()` calls corroborate the absence of administrative setup.

The supplied protected tests were read but are not executable unchanged under this project's pinned Solidity
0.8.28 configuration: they pin 0.8.26, and `Owners.protected.t.sol` imports an absent `floor/OwnerChecks.sol`.
The local rehearsal covers deployment and runtime constraints; it does not claim to execute that missing
owner harness. No Slither/Mythril run or live deployment was performed. Accepted limitations in the brief
remain accepted, including permissionless posting, arbitrary vault/target ids, byte-counted unfiltered text,
unlimited reply depth, and permanent history.

## Validation

Ran with the project's unchanged configuration and the required seed:

```sh
FOUNDRY_FUZZ_SEED=0x27c846b3278e4772ff4e2d63f61f6d94fe0bb177bf8ae38011cee8b004c05610 forge build
FOUNDRY_FUZZ_SEED=0x27c846b3278e4772ff4e2d63f61f6d94fe0bb177bf8ae38011cee8b004c05610 forge test
```

- **Build:** passed. Existing compiler warnings concern other project contracts; DareComments needs no change.
- **Full suite:** 717 passed, 0 failed, 4 skipped across 92 suites. This retains all 709 original passing tests
  and adds the eight launch/reader tests. The four skipped cases require a mainnet fork; live integrations
  were not exercised.
- **Focused comments suite:** 27 passed, 0 failed, 0 skipped, including the original 19 and all eight new tests.
  The original fuzz tests ran 256 cases each with the specified seed.
- **Compiled artifact:** all six function signatures, input/output types and mutabilities, all three errors,
  and the full event layout/indexing match the fixed ABI. Creation code is 958 bytes; runtime is 932 bytes.
  Neither contains external library link references. The focused and default builds produce identical
  DareComments ABI and bytecode.
- **Change check:** existing production sources, original tests, protected configuration and dependencies
  match their pre-edit file hashes. Only the launch document was edited; the adaptation record and new test
  file were added. Whitespace checks passed.
