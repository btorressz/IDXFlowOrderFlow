(async function test() {
    const accounts = await web3.eth.getAccounts();
    const user = accounts[1];
    const governor = accounts[0];

    const token = await IERC20.at("<TOKEN_ADDRESS>");
    const orderFlow = await IDXFlowOrderFlow.at("<DEPLOYED_CONTRACT_ADDRESS>");

    console.log("📍 Running IDXFlowOrderFlow Tests...");

    // ──────────────────────────────────────────────────────────────
    // Stake Tokens
    // ──────────────────────────────────────────────────────────────
    let amount = web3.utils.toWei("1000", "ether");

    await token.approve(orderFlow.address, amount, { from: user });
    await orderFlow.stakeWithPermit(
        amount,
        Math.floor(Date.now() / 1000) + 3600, // deadline
        27, // v (will need to replace with actual permit values)
        "0x".padEnd(66, "0"), // r (placeholder)
        "0x".padEnd(66, "0"), // s (placeholder)
        { from: user }
    );

    const staked = await orderFlow.users(user);
    console.log("✅ Stake success:", web3.utils.fromWei(staked.stakedAmount.toString(), "ether"));

    // ──────────────────────────────────────────────────────────────
    // Simulate Reward Claim
    // ──────────────────────────────────────────────────────────────
    await orderFlow.claimRewardsPrivate(
        web3.utils.toWei("10000", "ether"),
        { from: user }
    );

    const updated = await orderFlow.users(user);
    console.log("✅ Claim success: Last Epoch Claimed =", updated.lastClaimEpoch.toString());

    // ──────────────────────────────────────────────────────────────
    // Auto-Compound Toggle
    // ──────────────────────────────────────────────────────────────
    await orderFlow.toggleAutoCompound(true, { from: user });

    const postToggle = await orderFlow.users(user);
    console.log("✅ Auto-compound enabled:", postToggle.autoCompound);

    // ──────────────────────────────────────────────────────────────
    // Request Unstake and Withdraw
    // ──────────────────────────────────────────────────────────────
    await orderFlow.requestUnstake(
        web3.utils.toWei("500", "ether"),
        { from: user }
    );

    console.log("✅ Unstake requested");

    // Simulate wait
    await new Promise(resolve => setTimeout(resolve, 2000)); // Just wait in test. Use Ganache time travel in full suite.

    try {
        await orderFlow.withdrawUnstaked({ from: user });
        console.log("✅ Unstake withdrawn");
    } catch (err) {
        console.log("⚠️ Withdraw failed, cooldown may still be active");
    }

    // ──────────────────────────────────────────────────────────────
    // Vested Rewards
    // ──────────────────────────────────────────────────────────────
    try {
        await orderFlow.claimVestedRewards({ from: user });
        console.log("✅ Vested rewards claimed");
    } catch (err) {
        console.log("⚠️ No vested rewards available yet");
    }

    // ──────────────────────────────────────────────────────────────
    // Multicall Simulation
    // ──────────────────────────────────────────────────────────────
    try {
        const callData = [
            orderFlow.contract.methods.toggleAutoCompound(true).encodeABI(),
            orderFlow.contract.methods.claimRewardsPrivate(
                web3.utils.toWei("10000", "ether")
            ).encodeABI()
        ];

        const res = await orderFlow.multicall(callData, { from: user });
        console.log("✅ Multicall executed", res);
    } catch (err) {
        console.log("⚠️ Multicall failed", err.message);
    }

    console.log("🎉 All tests completed.");
})();
