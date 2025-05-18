import { expect } from "chai";
import hre from "hardhat";
import { Signer, ContractFactory, ContractTransactionReceipt, BaseContract } from "ethers";
import { DemoToken, MainAMM } from "../typechain-types";


type HardhatSigner = Awaited<ReturnType<typeof hre.ethers.getSigner>>
let once: boolean = false;
describe("CPMM", function () {
    let t0Token, t1Token, amm: ContractFactory;
    let t0Ins: DemoToken, t1Ins: DemoToken, ammIns: MainAMM;
    let owner: HardhatSigner, lp: HardhatSigner, trader: HardhatSigner, trader2: HardhatSigner;


    // we deploy two tokens; get the address of each and
    // use them as the pair for our amm tests
    this.beforeEach(async function(){
        [owner, lp, trader, trader2] = await hre.ethers.getSigners();

        t0Token = await hre.ethers.getContractFactory("DemoToken");
        t0Ins = await t0Token.connect(owner).deploy(100000n, "t0", "t0");

        t1Token = await hre.ethers.getContractFactory("DemoToken");
        t1Ins = await t1Token.connect(owner).deploy(100000n, "t1", "t1");

        amm = await hre.ethers.getContractFactory("MainAMM");
        ammIns = await amm.connect(owner).deploy(await t0Ins.getAddress(), await t1Ins.getAddress(), owner);

     
            console.log("T0 => "+ await t0Ins.getAddress()); 
            console.log("T1 => "+ await t1Ins.getAddress()); 
            console.log("AMM => "+ await ammIns.getAddress()); 
            console.log("Owner => "+ await owner.getAddress()); 
            console.log("Lp => "+ await lp.getAddress()); 
            console.log("Trader => "+ await trader.getAddress()); 
      
    })

    it("OK: Must be able to set initial liquidity & k ratio", async function () {
        t0Ins.connect(owner).approve(ammIns, 100n);
        t1Ins.connect(owner).approve(ammIns, 100n);
        await ammIns.connect(owner).bootstrap(t0Ins.getAddress(), t1Ins.getAddress(), 100n, 100n);
        let res = await ammIns.connect(owner).balances(t0Ins.getAddress());
        let res1 = await ammIns.connect(owner).balances(t1Ins.getAddress());
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
        t0Ins.connect(owner).approve(ammIns, 100n);
        t1Ins.connect(owner).approve(ammIns, 100n);
        (await ammIns.connect(owner).bootstrap(t0Ins.getAddress(), t1Ins.getAddress(), 100n, 100n)).wait();
        expect(await t0Ins.balanceOf(ammIns)).to.equal(100n);
        await t0Ins.connect(owner).transfer(trader.getAddress(), 10n);
        await t0Ins.connect(trader).approve(ammIns.getAddress(), 10n);
        expect(await ammIns.connect(owner).t0t1Ratio()).to.equal(100n);
        expect(await ammIns.connect(owner).t1t0Ratio()).to.equal(100n);
        let [amountInAfterFee, amountOut] = await ammIns.connect(trader)._calcAmountOut.staticCall(t0Ins.getAddress(), 20n);
        console.log(amountInAfterFee, amountOut);
        var lpRes = await ammIns.connect(trader).swap(t0Ins.getAddress(), 10n);
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
        t0Ins.connect(owner).approve(ammIns, 100n);
        t1Ins.connect(owner).approve(ammIns, 100n);
        await ammIns.connect(owner).bootstrap(t0Ins.getAddress(), t1Ins.getAddress(), 100n, 100n);
        await t0Ins.connect(owner).transfer(lp.getAddress(), 20n);
        await t1Ins.connect(owner).transfer(lp.getAddress(), 20n);
        
        await t0Ins.connect(lp).approve(ammIns.getAddress(), 20n);
        await t1Ins.connect(lp).approve(ammIns.getAddress(), 20n);
        var lpRes = await ammIns.connect(lp).addLiquidity(20n, 20n);
        expect(await ammIns.connect(owner).t0t1Ratio()).to.equal(100n);
        expect(await ammIns.connect(owner).t1t0Ratio()).to.equal(100n);

        let lpToken = await ammIns.balanceOf(lp);
                
        expect(lpToken).to.equal(20n);
    });


    // test includes:
    it("OK: first swap, then add liquidity; ratio must be forced", async function () {
        await swapTest();


        const token0ToSpend = 20n;
        const token1ToSpend = 20n;
        // now continue the test
        await t0Ins.connect(owner).transfer(lp.getAddress(), token0ToSpend);
        await t1Ins.connect(owner).transfer(lp.getAddress(), token1ToSpend);

        await t0Ins.connect(lp).approve(ammIns.getAddress(), token0ToSpend);
        await t1Ins.connect(lp).approve(ammIns.getAddress(), token1ToSpend);    

        let [a0, a1, lpToken] = await ammIns.connect(lp).addLiquidity.staticCall(10n, 6n);
        expect(a0).to.equal(7n);
        expect(a1).to.equal(6n);
        expect(lpToken).to.equal(6n);
        await ammIns.connect(lp).addLiquidity(10n, 6n);

        expect(await t0Ins.connect(lp).balanceOf(lp.address)).to.equal(token0ToSpend - a0);
        expect(await t1Ins.connect(lp).balanceOf(lp.address)).to.equal(token1ToSpend - a1);
        expect(await ammIns.connect(lp).balanceOf(lp.address)).to.equal(lpToken);
    });
});