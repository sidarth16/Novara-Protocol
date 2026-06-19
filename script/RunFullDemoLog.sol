// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";

import {SepoliaDemoWorkflow} from "./utils/SepoliaDemoWorkflow.sol";

contract RunFullDemoLog is SepoliaDemoWorkflow {
    function run() external {
        DemoContext memory ctx = _context();
        require(_positionExists(ctx), "no tracked position");

        console2.log("");
        console2.log("========================================");
        console2.log("           NOVARA DEMO");
        console2.log("========================================");
        console2.log("");
        console2.log("Yield-Aware LP Protection");
        console2.log("");

        // ============================================================
        // STEP 1
        // ============================================================

        console2.log("----------------------------------------");
        console2.log("[STEP 1] ACTIVE POSITION");
        console2.log("----------------------------------------");

        console2.log("Position ID:");
        console2.logBytes32(ctx.positionId);

        console2.log("Lower Tick", int256(-60));
        console2.log("Upper Tick", int256(60));

        console2.log("State ACTIVE");
        console2.log("");

        _printPosition(ctx, ctx.positionId);

        console2.log("");
        console2.log("Initial Reserve Snapshot");
        _printReserve(ctx);

        vm.startBroadcast(vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY));

        // ============================================================
        // STEP 2
        // ============================================================

        console2.log("");
        console2.log("----------------------------------------");
        console2.log("[STEP 2] OUT OF RANGE");
        console2.log("----------------------------------------");

        _reproduceOutOfRange(ctx);

        console2.log("State Transition:");
        console2.log("ACTIVE -> YIELD MODE");

        console2.log("Liquidity withdrawn from pool");
        console2.log("Capital deployed into yield strategy");
        console2.log("");

        _printAaveAndVault(ctx, ctx.positionId);

        console2.log("");
        console2.log("Reserve Snapshot");
        _printReserve(ctx);

        // ============================================================
        // STEP 3
        // ============================================================

        console2.log("");
        console2.log("----------------------------------------");
        console2.log("[STEP 3] ACCRUE YIELD");
        console2.log("----------------------------------------");

        uint256 accrued = _accrueYield(ctx);

        console2.log("Yield Accrued", accrued);
        console2.log("");

        _printAaveAndVault(ctx, ctx.positionId);

        // ============================================================
        // STEP 4
        // ============================================================

        console2.log("");
        console2.log("----------------------------------------");
        console2.log("[STEP 4] AUTOMATION CHECK");
        console2.log("----------------------------------------");

        (bool upkeepNeeded, bytes memory performData) = _reenterRange(ctx);

        console2.log("Upkeep Needed", upkeepNeeded);

        if (upkeepNeeded) {
            console2.log("Position ready for redeployment");
        } else {
            console2.log("Position remains in yield mode");
        }

        // ============================================================
        // STEP 5
        // ============================================================

        console2.log("");
        console2.log("----------------------------------------");
        console2.log("[STEP 5] REDEPLOY LIQUIDITY");
        console2.log("----------------------------------------");

        _performUpkeep(ctx, performData);

        console2.log("State Transition:");
        console2.log("YIELD MODE -> ACTIVE");

        console2.log("Capital recalled from vault");
        console2.log("Liquidity redeployed into Uniswap");
        console2.log("");

        _printAaveAndVault(ctx, ctx.positionId);

        console2.log("");
        console2.log("Reserve Snapshot");
        _printReserve(ctx);

        // ============================================================
        // STEP 6
        // ============================================================

        console2.log("");
        console2.log("----------------------------------------");
        console2.log("[STEP 6] PROTECTED EXIT");
        console2.log("----------------------------------------");

        uint256 ilAmount = _exitLiquidity(ctx);

        console2.log("State Transition:");
        console2.log("ACTIVE -> EXITED");

        console2.log("Impermanent Loss", ilAmount);
        console2.log("");

        _printReserve(ctx);

        vm.stopBroadcast();

        // ============================================================
        // SUMMARY
        // ============================================================

        console2.log("");
        console2.log("========================================");
        console2.log("          DEMO SUMMARY");
        console2.log("========================================");
        console2.log("");

        console2.log("[OK] Active Position");
        console2.log("[OK] Out-of-Range Detection");
        console2.log("[OK] Yield Vault Deployment");
        console2.log("[OK] Yield Accrual");
        console2.log("[OK] Automated Re-entry");
        console2.log("[OK] Protected Exit");
        console2.log("");

        console2.log("Lifecycle:");
        console2.log("ACTIVE -> YIELD MODE -> ACTIVE -> EXITED");
        console2.log("");

        console2.log("Final Position State");
        _printPosition(ctx, ctx.positionId);

        console2.log("");
        console2.log("Demo Complete");
        console2.log("");
    }    
}
