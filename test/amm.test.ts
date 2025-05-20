import { expect } from "chai";
import hre from "hardhat";
import { Signer, ContractFactory, ContractTransactionReceipt, BaseContract } from "ethers";
import { DemoToken, MainAMM } from "../typechain-types";

interface AddrCollection {
        main: string, t0: string, t1: string
};
type HardhatSigner = Awaited<ReturnType<typeof hre.ethers.getSigner>>
let once: boolean = false;
describe("CPMM", function () {
    let t0Token, t1Token, amm: ContractFactory;
    let t0Ins: DemoToken, t1Ins: DemoToken, ammIns: MainAMM;
    let owner: HardhatSigner, lp: HardhatSigner, trader: HardhatSigner, trader2: HardhatSigner;
    let addr: AddrCollection = { main: "", t0: "", t1: ""};

    // we deploy two tokens; get the address of each and
    // use them as the pair for our amm tests
    this.beforeEach(async function(){
        [owner, lp, trader, trader2] = await hre.ethers.getSigners();

        t0Token = await hre.ethers.getContractFactory("DemoToken");
        t0Ins = await t0Token.connect(owner).deploy(100000n, "t0", "t0");

        t1Token = await hre.ethers.getContractFactory("DemoToken");
        t1Ins = await t1Token.connect(owner).deploy(100000n, "t1", "t1");

        
        addr.t0 = await t0Ins.getAddress();
        addr.t1 = await t1Ins.getAddress();
        
        amm = await hre.ethers.getContractFactory("MainAMM");
        ammIns = await amm.connect(owner).deploy(await addr.t0, await addr.t1, owner);
            console.log("T0 => "+ await addr.t0); 
            console.log("T1 => "+ await addr.t1); 
            console.log("AMM => "+ await ammIns.getAddress()); 
            console.log("Owner => "+ await owner.getAddress()); 
            console.log("Lp => "+ await lp.getAddress()); 
            console.log("Trader => "+ await trader.getAddress()); 
      
        addr.main = await ammIns.getAddress();
        
    })

    it("OK: Must be able to set initial liquidity & k ratio", async function () {
        (await t0Ins.connect(owner).approve(ammIns, 100n)).wait();
        (await t1Ins.connect(owner).approve(ammIns, 100n)).wait();
        (await ammIns.connect(owner).bootstrap(addr.t0, addr.t1, 100n, 100n)).wait();
        let res = await ammIns.connect(owner).reserves(addr.t0);
        let res1 = await ammIns.connect(owner).reserves(addr.t1);
        let k = await ammIns.connect(owner).ratioK();
        expect(res).to.equal(100n);
        expect(res1).to.equal(100n);
        expect(k).to.equal(100n * 100n);
        expect(await ammIns.connect(owner).t0t1Ratio()).to.equal(100n);
    });


    // test includes:
    // -1 allowance for the main amm contract for both token
    // -2 bootstrapping the contract and setting the initial liquidity pool
    // -3 as a trader, do a swapping, which includes: allowance for the contract
    //    to transfer the amount from tokenIn, spending it, and transfer the equivalence
    //    in tokenOut based on the ratio and global K to the trader's address
    // -4 a couple of expect()..equal() ensures the numbers match
    let swapTest = async function() {
        (await t0Ins.connect(owner).approve(addr.main, 100n)).wait();
        (await t1Ins.connect(owner).approve(addr.main, 100n)).wait();
        expect(await t0Ins.allowance(owner.getAddress(), ammIns.getAddress())).to.equal(100n);
        (await ammIns.connect(owner).bootstrap(addr.t0, addr.t1, 100n, 100n)).wait();
        expect(await t0Ins.balanceOf(ammIns)).to.equal(100n);
        await t0Ins.connect(owner).transfer(trader.getAddress(), 10n);
        await t0Ins.connect(trader).approve(ammIns.getAddress(), 10n);
        expect(await ammIns.connect(owner).t0t1Ratio()).to.equal(100n);
        expect(await ammIns.connect(owner).t1t0Ratio()).to.equal(100n);
        let [amountInAfterFee, amountOut] = await ammIns.connect(trader)._calcAmountOut.staticCall(addr.t0, 20n);

        var lpRes = await ammIns.connect(trader).swap(addr.t0, 10n);
        let k = await ammIns.connect(owner).ratioK();
        expect(k).to.equal(100*100);
        expect(await ammIns.connect(owner).t0t1Ratio()).to.equal(91n);
        expect(await ammIns.connect(owner).t1t0Ratio()).to.equal(109n);
        expect(await t1Ins.balanceOf(trader)).to.equal(9);
    }

    
    it("OK: successfull swapping", async function () {
        await swapTest();
    });

    // test includes:
    // approving allowance for both token
    // transfering x amount to LP user of both token
    // LP adding liquidity of x amount 
    it("OK: adding liquidity to the pool by an LP", async function () {
        (await t0Ins.connect(owner).approve(ammIns, 100n)).wait();
        (await t1Ins.connect(owner).approve(ammIns, 100n)).wait();
        await ammIns.connect(owner).bootstrap(addr.t0, addr.t1, 100n, 100n);
        await t0Ins.connect(owner).transfer(lp.address, 20n);
        await t1Ins.connect(owner).transfer(lp.address, 20n);
        
        await t0Ins.connect(lp).approve(await ammIns.getAddress(), 20n);
        await t1Ins.connect(lp).approve(await ammIns.getAddress(), 20n);
        var lpRes = await ammIns.connect(lp).addLiquidity(20n, 20n);
        expect(await ammIns.connect(owner).t0t1Ratio()).to.equal(83n);
        expect(await ammIns.connect(owner).t1t0Ratio()).to.equal(83n);

        let lpToken = await ammIns.balanceOf(lp);
                
        expect(lpToken).to.equal(20n);
    });


    // test includes:
    it("OK: first swap, then add liquidity; ratio must be forced", async function () {
        await swapTest();
        const token0ToSpend = 30n;
        const token1ToSpend = 30n;
        // now continue the test
        await t0Ins.connect(owner).transfer(lp.address, token0ToSpend);
        await t1Ins.connect(owner).transfer(lp.address, token1ToSpend);

        await t0Ins.connect(lp).approve(await ammIns.getAddress(), token0ToSpend);
        await t1Ins.connect(lp).approve(await ammIns.getAddress(), token1ToSpend);    

        let [a0, a1, lpToken] = await ammIns.connect(lp).addLiquidity.staticCall(30n, 10n);
        // console.log(a0, a1, lpToken);
        expect(a0).to.equal(11n);
        expect(a1).to.equal(10n);
        expect(lpToken).to.equal(10n);
        let tx = await ammIns.connect(lp).addLiquidity(30n, 10n);
        tx.wait();
        expect(await t0Ins.connect(lp).balanceOf(lp.address)).to.equal(token0ToSpend - a0);
        expect(await t1Ins.connect(lp).balanceOf(lp.address)).to.equal(token1ToSpend - a1);
        expect(await ammIns.connect(lp).balanceOf(lp.address)).to.equal(lpToken);
    });

    it("OK: first swap, then add liquidity; ratio must be forced; then burn", async function () {
        await swapTest();
        const token0ToSpend = 30n;
        const token1ToSpend = 30n;
        // now continue the test
        await t0Ins.connect(owner).transfer(lp.address, token0ToSpend);
        await t1Ins.connect(owner).transfer(lp.address, token1ToSpend);

        await t0Ins.connect(lp).approve(addr.main, token0ToSpend);
        await t1Ins.connect(lp).approve(addr.main, token1ToSpend);    

        let [a0, a1, lpToken] = await ammIns.connect(lp).addLiquidity.staticCall(30n, 10n);
        expect(a0).to.equal(11n);
        expect(a1).to.equal(10n);
        expect(lpToken).to.equal(10n);
        let tx = await ammIns.connect(lp).addLiquidity(30n, 10n);
        tx.wait();
        expect(await t0Ins.connect(lp).balanceOf(lp.address)).to.equal(token0ToSpend - a0);
        expect(await t1Ins.connect(lp).balanceOf(lp.address)).to.equal(token1ToSpend - a1);
        expect(await ammIns.connect(lp).balanceOf(lp.address)).to.equal(lpToken);

        (await ammIns.connect(lp).approve(addr.main, 5n)).wait();
        expect(await ammIns.connect(lp).allowance(lp.address, addr.main)).to.equal(5n);
        (await ammIns.connect(lp).burnLiquidity(5n)).wait();
        expect(await ammIns.connect(lp).balanceOf(lp.address)).to.equal(10n/2n);
    });
});