## Me

> Context:
> - <rules>/home/heefoo/.claude/CLAUDE.md</rules>
> -  <buf>src/stable_index_vector.c3</buf>


#{buffer} check the fan eraser interaction

## CodeCompanion (Codex)

### Reasoning



**Planning file inspection for interaction diagnosis**

### Response

I’ll inspect the stable-index vector implementation and its surrounding interaction logic, then trace the fan/eraser path for invariants, edge cases, and likely failure points. I’ll keep this to a read-only review unless you want a fix applied.

Execute: /usr/bin/zsh -lc "sed -n '1,260p' src/stable_index_vector...

### Reasoning



**Inspecting file references with ripgrep**

### Response


Search: Search for 'fan|eraser|stable.?index|StableIndex|remove_i...

### Reasoning



**Inspecting main and test files**

### Response


Execute: /usr/bin/zsh -lc "sed -n '1,240p' src/main.c3 && printf '...

### Reasoning



**Planning test compilation and inspection**

### Response


Execute: sed -n '1,200p' project.json && c3c test --help >/dev/nul...

### Reasoning



**Planning c3c test execution**

### Response


Execute: c3c test --help | sed -n '1,120p'; c3c test

### Reasoning



**Identifying fan eraser interaction bugs**

**Analyzing port and wire deletion sequencing**

### Response

The stable-index-vector tests pass, so the container’s unordered-erase/ID-reuse behavior is internally sound. The fan/eraser interaction has separate semantic issues in `interact`; I’m checking exact line locations and whether the current code compiles only because those paths are not exercised.

Execute: nl -ba src/main.c3 | sed -n '80,205p'; printf '\n--- stat...

### Reasoning



**Planning compile verification with c3c build**

### Response

The stable-index vector itself looks healthy: all six existing tests pass, including unordered erase, handle invalidation, ID reuse, `erase_at`, and `remove_if`.

The fan/eraser interaction in [`src/main.c3`](/home/heefoo/Documents/code/c3-experiments/delta_net_abstract_machine/src/main.c3) is not complete or orientation-safe, though.

Main findings:

1. Fan–eraser handling only works in one endpoint order

At lines [117–121](/home/heefoo/Documents/code/c3-experiments/delta_net_abstract_machine/src/main.c3:117), the code switches on `node_a.type`, and the implementation exists only for:

```c3
node_a == ERASER
node_b == FAN
```

If the same active wire is passed with the fan at endpoint A and the eraser at endpoint B, execution reaches:

```c3
case FAN:
  io::printn("Fan");
```

and performs no rewrite. Interaction selection must either canonicalize the endpoints first or handle both permutations.

A simple normalization would be conceptually:

```c3
if (node_a.type == FAN && node_b.type == ERASER)
{
    swap(node_a, node_b);
    swap(node_a_id, node_b_id);
    swap(port_a, port_b);
}
```

Then the existing implementation could assume `node_a` is the eraser and `node_b` is the fan.

2. Eraser–eraser interaction does not erase anything

The nested branch at [172–173](/home/heefoo/Documents/code/c3-experiments/delta_net_abstract_machine/src/main.c3:172) only prints `"ERASER"`.

For an eraser–eraser redex, the expected rewrite is presumably to remove both eraser nodes, their connecting principal ports, and the active wire. Currently the interaction leaves the net unchanged apart from console output.

The missing operation would be equivalent to:

```c3
net.nodes.erase(node_a_id);
net.nodes.erase(node_b_id);
net.wires.erase(wire_id);
net.ports.erase(wire_a_id);
net.ports.erase(wire_b_id);
```

The exact ordering should be kept consistent with the rest of the rewrite.

3. The child wires are marked alive unconditionally

At [147–148](/home/heefoo/Documents/code/c3-experiments/delta_net_abstract_machine/src/main.c3:147), the two fan child wires are set to `alive = true`.

That is suspicious because:

- `alive` is never consulted by [`is_active`](/home/heefoo/Documents/code/c3-experiments/delta_net_abstract_machine/src/main.c3:92).
- `interact` also does not check it.
- A wire’s existence is already represented by its presence in `StableIndexVector`.
- If a child wire had already been logically deactivated, this rewrite silently reactivates it.

Either `alive` should be removed, or it should be part of the wire lifecycle and checked consistently:

```c3
fn bool is_active(Net* net, StableId wire_id)
{
    Wire* wire = net.wires.get_ref(wire_id);
    if (!wire.alive) return false;

    Port* port_a = net.ports.get_ref(wire.a);
    Port* port_b = net.ports.get_ref(wire.b);
    return port_a.type == PRINCIPAL && port_b.type == PRINCIPAL;
}
```

If erasing a wire means it no longer exists, `alive` is probably redundant.

4. The rewrite depends on implicit port orientation

The code obtains the fan’s child ports using:

```c3
Port* port_left = net.ports.get_ref(node_b.agent.fan.left);
Port* port_right = net.ports.get_ref(node_b.agent.fan.right);
```

and then replaces their `nodeId` and `type` fields with the new eraser nodes.

That is reasonable if the fan’s `left` and `right` fields always refer to the actual port IDs connected to the child wires. However, the code does not verify:

- that each port’s `wireId` is valid;
- that each child wire actually contains that port as endpoint `a` or `b`;
- that the fan’s principal port is exactly `wire_a_id`/`wire_b_id`;
- that the left and right ports are distinct;
- that neither child wire is the redex wire being deleted.

Malformed or stale IDs will trigger assertions inside `get_ref`, while inconsistent topology may silently produce a corrupt net.

5. `node_a` and `node_b` pointers are safe only because they are not used after insertion

The code caches:

```c3
Node* node_a = net.nodes.get_ref(node_a_id);
Node* node_b = net.nodes.get_ref(node_b_id);
```

Then it pushes two new nodes at [144–145](/home/heefoo/Documents/code/c3-experiments/delta_net_abstract_machine/src/main.c3:144).

`StableIndexVector.push` may reallocate its dense storage, invalidating those raw pointers. In this particular code path, the pointers are only used to read the node types and fan ports before the pushes, so there is no immediate use-after-reallocation. Still, this is fragile. It would be safer to copy the required IDs and values into locals before pushing:

```c3
AgentType node_a_type = node_a.type;
AgentType node_b_type = node_b.type;
StableId fan_left_id = node_b.agent.fan.left;
StableId fan_right_id = node_b.agent.fan.right;
```

Then use only those locals after mutation.

6. Stable IDs protect references, but not raw pointers or dense indexes

The stable-index implementation correctly preserves IDs when another element is erased. However, the comments in [`stable_index_vector.c3`](/home/heefoo/Documents/code/c3-experiments/delta_net_abstract_machine/src/stable_index_vector.c3:24) are important here: raw pointers and dense indexes are invalidated by push/erase.

The interaction code currently follows the safe pattern for the port pointers because node insertion affects only `net.nodes`, not `net.ports`. It also correctly saves the port and node IDs before erasing. This part is compatible with the container design.

7. The node rewrite itself is structurally plausible for eraser–fan

For the supported orientation, the intended sequence appears to be:

- Read the eraser/fan principal connection.
- Read the fan’s left and right ports.
- Create one eraser for each child wire.
- Reassign each child port to its new eraser node.
- Remove the old eraser node and fan node.
- Remove the principal wire and its two principal ports.

That topology transformation is sensible. The major blocker is that it is implemented only for one direction, and the eraser–eraser case is unfinished.

I would prioritize the fixes in this order:

1. Normalize or support both fan/eraser endpoint orders.
2. Implement eraser–eraser deletion.
3. Decide whether `Wire.alive` is necessary; currently it is inconsistent and effectively unused.
4. Add topology assertions or a dedicated helper for validating/rebinding wire endpoints.
5. Add interaction tests for:

   - eraser–fan;
   - fan–eraser;
   - eraser–eraser;
   - child wires becoming active after fan elimination;
   - stale/invalid wire IDs;
   - repeated interaction attempts on the removed redex.

The current project builds far enough for the existing stable-vector tests, but there are no tests exercising `interact`, so the fan/eraser behavior is presently unverified.

## Me

> Context:
> - <rules>/home/heefoo/.claude/CLAUDE.md</rules>
> -  <buf>src/stable_index_vector.c3</buf>


