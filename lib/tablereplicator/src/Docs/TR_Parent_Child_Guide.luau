--[=[
    @class TR Parent-Child Guide

    Replicators can be nested into a hierarchy. A **child** replicator is owned by a
    parent and automatically inherits its top-level ancestor's replication targets, so
    you describe *who sees what* once (at the top level) and the whole subtree follows.

    ---
    ### Top-level vs child

    A replicator is created as one or the other, decided by which field you pass:

    - **Top-level** — created with `Targets`. It owns a replication *scope*.
    - **Child** — created with `Parent` (instead of `Targets`). It joins its parent's
        scope and replicates to exactly the players the top-level ancestor targets.

    ```lua
    local root = ServerReplicator.new({
        Namespace = "Party",
        Data = { Name = "The Crew" },
        Targets = "all",
    })

    local member = ServerReplicator.new({
        Namespace = "PartyMember",
        Data = { Ready = false },
        Parent = root, -- inherits root's targets; do NOT also pass Targets
    })
    ```

    :::caution Exactly one of `Targets` or `Parent`
    Passing both throws, as does passing neither. A child never sets its own targets —
    change the top-level ancestor's targets (or reparent) instead.
    :::

    ---
    ### Traversing the hierarchy

        The same traversal API exists on both [ServerReplicator](/api/ServerReplicator) and
    [ClientReplicator](/api/ClientReplicator):
    ```lua
    root:IsTopLevel()          -- true (no parent)
    member:GetParent()         -- root
    root:GetChildren()         -- { member, ... } (immediate children only)
    root:GetDescendants()      -- every descendant, recursively

    -- Find a specific child by any SearchCondition (string / token / tags / predicate):
    root:FindFirstChild("PartyMember")          -- immediate children
    root:FindFirstChild({ Ready = true }, true) -- recursive

    -- Promise-based: resolves now if a match exists, otherwise when one is added.
    root:PromiseFirstChild("PartyMember"):andThen(function(child) end)
    ```

    Hierarchy changes are observable through per-replicator signals:

    ```lua
    root.ChildAdded:Connect(function(child) end)
    root.ChildRemoved:Connect(function(child) end)
    member.ParentChanged:Connect(function(newParent, oldParent) end)
    ```


    ---
    ### Reparenting

    `SetParent` moves a replicator **and its entire subtree** under a new parent. It
    works on the client automatically — the server computes the minimal set of
    create/destroy/reparent messages so each player ends up consistent:

    ```lua
    member:SetParent(otherRoot)
    ```

    If the move crosses scope boundaries (a different top-level ancestor), players who
    can only see the old scope receive a destroy, players who can only see the new scope
    receive a fresh snapshot, and players in both receive a lightweight reparent.

    :::caution Server-side, no cycles, not top-level
    `SetParent` is a server API. It throws if called on a top-level replicator or if the
    new parent is one of the replicator's own descendants (which would form a cycle).
    :::

    ### The `All` and `None` sentinels

    Two ready-made top-level replicators exist as convenient parents. Don't mutate them —
    only parent to them:

    ```lua
    -- Visible to every current and future player.
    local child = ServerReplicator.new({ Data = ..., Parent = ServerReplicator.All })

    -- Visible to nobody yet — a "parking spot" until a real parent is chosen.
    local pending = ServerReplicator.new({ Data = ..., Parent = ServerReplicator.None })
    pending:SetParent(realParent) -- promote it later
    ```

    ---
    ### Destruction
    A replicator cannot be destroyed while it still has children — that would silently
    orphan them. `ServerReplicator:Destroy` handles this for you by reparenting each
    child to `ServerReplicator.None` before tearing itself down:

    ```lua
    root:Destroy() -- children survive, reparented to ServerReplicator.None
    ```

    If you want the whole subtree gone, destroy the descendants first (deepest-first),
    or destroy each child explicitly before the parent.

    :::note Clients don't destroy
    On the client, destruction is entirely server-driven — the server sends a single
    destroy for the root of a removed subtree and the client tears the whole subtree
    down. Calling `Destroy` on a `ClientReplicator` errors.
    :::

    ---
    ### See also

    - **[TR Getting Started](/api/TR%20Getting%20Started)** — creating your first top-level replicator.
    - **[TR Discovery & Targeting](/api/TR%20Discovery%20&%20Targeting)** — how targeting works and how children inherit it.

]=]
