[![CI](https://github.com/Raild3x/ModulesOnRails/actions/workflows/ci.yml/badge.svg)](https://github.com/Raild3x/ModulesOnRails/actions/workflows/ci.yml) [![Docs](https://img.shields.io/badge/docs-site-blue)](https://raild3x.github.io/ModulesOnRails/) [![License](https://img.shields.io/github/license/Raild3x/ModulesOnRails)](https://github.com/Raild3x/ModulesOnRails/blob/main/LICENSE) [![Coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FRaild3x%2FModulesOnRails%2Fbadges%2Fcoverage.json)](https://github.com/Raild3x/ModulesOnRails/actions/workflows/coverage-badge.yml)

![ModulesOnRails banner](https://raw.githubusercontent.com/Raild3x/ModulesOnRails/main/brand/banner_logo.png)

ModulesOnRails is a collection of Wally packages to streamline Roblox development.

# Packages

| Package | Latest Version | Description |
|---------|----------------|-------------|
| [BaseComponent](https://raild3x.github.io/ModulesOnRails/api/BaseComponent) | `BaseComponent = "raild3x/basecomponent@0.1.2"` | A utility extension to provide helpers for working with signals, janitors, attributes, and properties. *Only works with my Component fork.* |
| [BaseObject](https://raild3x.github.io/ModulesOnRails/api/BaseObject) | `BaseObject = "raild3x/baseobject@0.2.2"` | A base class for creating objects with a lifecycle, janitor, and event system. |
| [CmdrHandler](https://raild3x.github.io/ModulesOnRails/api/CmdrHandler) | `CmdrHandler = "raild3x/cmdrhandler@0.2.2"` | A wrapper for eveara/quenty's Cmdr library. |
| [Component](https://raild3x.github.io/ModulesOnRails/api/Component) | `Component = "raild3x/component@0.2.0"` | A fork of Sleitnick's Component class for Roblox. |
| [DragDrop](https://raild3x.github.io/ModulesOnRails/api/DragDrop) | `DragDrop = "raild3x/dragdrop@0.2.0"` | A device-agnostic drag-and-drop system for Roblox UI (mouse, touch, gamepad, keyboard). |
| [Graph Utilities](https://raild3x.github.io/ModulesOnRails/api/GraphUtil) | `Graph Utilities = "raild3x/graphutil@0.2.0"` | A collection of Graph utilities |
| [Heap](https://raild3x.github.io/ModulesOnRails/api/Heap) | `Heap = "raild3x/heap@2.1.4"` | A generic min/max heap implementation in Luau. |
| [Loose-Tight-Double-Grid](https://raild3x.github.io/ModulesOnRails/api/LooseTightDoubleGrid) | `Loose-Tight-Double-Grid = "raild3x/loosetightdoublegrid@1.2.1"` | A spatial partitioning system to query varied size entities in 2d space. |
| [NetWire](https://raild3x.github.io/ModulesOnRails/api/NetWire) | `NetWire = "raild3x/netwire@0.3.4"` | A networking library based off of sleitnicks comm library. |
| [ObjectCache](https://raild3x.github.io/ModulesOnRails/api/ObjectCache) | `ObjectCache = "raild3x/objectcache@0.0.2"` | A fork of Pyseph's ObjectCache module, with some additional features. |
| [ProbabilityDistributor](https://raild3x.github.io/ModulesOnRails/api/ProbabilityDistributor) | `ProbabilityDistributor = "raild3x/probabilitydistributor@1.0.6"` | A class for distributing probability. |
| [PromValue](https://raild3x.github.io/ModulesOnRails/api/PromValue) | `PromValue = "raild3x/promvalue@0.1.0"` | An object class that allows for delayed setting |
| [Quadtree](https://raild3x.github.io/ModulesOnRails/api/Quadtree) | `Quadtree = "raild3x/quadtree@0.0.3"` | A spatial partitioning system to query points in a 2D space. Refactored from Sleitnick's Octree package. |
| [Queue](https://raild3x.github.io/ModulesOnRails/api/Queue) | `Queue = "raild3x/queue@1.0.0"` | A generic queue implementation in luau. |
| [RemoteComponent](https://raild3x.github.io/ModulesOnRails/api/RemoteComponent) | `RemoteComponent = "raild3x/remotecomponent@0.2.0"` | A component extension to provide easy networking functionality. |
| [Roam](https://raild3x.github.io/ModulesOnRails/api/Roam) | `Roam = "raild3x/roam@0.2.0"` | Roam is a service initialization framework for Roblox. |
| [T](https://raild3x.github.io/ModulesOnRails/api/t) | `T = "raild3x/t@1.1.0"` | A runtime typechecker for Luau/Roblox |
| [TableManager](https://raild3x.github.io/ModulesOnRails/api/TableManager) | `TableManager = "raild3x/tablemanager@1.1.1"` | A Luau library for managing tables. |
| [TableReplicator](https://raild3x.github.io/ModulesOnRails/api/TableReplicator) | `TableReplicator = "raild3x/tablereplicator@1.0.1"` | Replicates a TableManager instance from server to client with minimal effort. |
| [UIParticleEmitter](https://raild3x.github.io/ModulesOnRails/api/UIParticleEmitter) | `UIParticleEmitter = "raild3x/uiparticleemitter@0.1.0"` | FusionComponent for emitting 2D images |


---

# Unreleased Packages

> ⚠️ **Warning:** The following packages are unreleased and have not been fully tested for production use. Use them at your own risk.

| Package | Latest Version | Description |
|---------|----------------|-------------|
| [AdjustableTimer](https://raild3x.github.io/ModulesOnRails/api/AdjustableTimer) | `AdjustableTimer = "raild3x/adjustabletimer@1.0.0"` | A timer class that can be easily adjusted and paused without constant ticking. |
| [AdjustableTimerManager](https://raild3x.github.io/ModulesOnRails/api/AdjustableTimerManager) | `AdjustableTimerManager = "raild3x/adjustabletimermanager@1.0.1"` | A replication manager for AdjustableTimer that allows for easy synchronization across clients in a Roblox game. It handles the replication of timer states and adjustments, ensuring that all clients have a consistent view of the timer's status. |
| [DropletManager](https://raild3x.github.io/ModulesOnRails/api/DropletManager) | `DropletManager = "raild3x/dropletmanager@0.1.0"` | A Droplet System for managing client-sided collectable items in a game. |
| [PlayerDataManager](https://raild3x.github.io/ModulesOnRails/api/PlayerDataManager) | `PlayerDataManager = "raild3x/playerdatamanager@0.1.2"` | A class for managing player profiles. |
| [PlayerProfileManager](https://raild3x.github.io/ModulesOnRails/api/PlayerProfileManager) | `PlayerProfileManager = "raild3x/playerprofilemanager@0.0.4"` | A class for managing player profiles. |

---

*Last Modified: July 22, 2026*
