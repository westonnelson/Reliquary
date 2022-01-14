const { assert, expect } = require("chai");
const { debug, deployChef, deployRewarder, deployCurve, tokenOfOwnerByIndex, tokenByIndex, totalPositions, returnChef,
  getGlobalInfo, viewPoolInfo, viewLpToken, viewRewarder, getPositionInfo, getPoolCount, addPool, set, pendingRelic,
  massUpdatePools, updatePool, createNewPositionAndDeposit, createNewPosition, deposit, withdraw, harvest,
  withdrawAndHarvest, emergencyWithdraw, curved } = require("../src/Reliquary.js");

let owner, alice, bob;

let zeroAddress = "0x0000000000000000000000000000000000000000";

describe("Reliquary", function () {
  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();

    const Oath = await ethers.getContractFactory("Oath");
    this.oath = await Oath.deploy("Oath", "OATH");
    this.lp = await Oath.deploy("LP Token", "LPT");
    await this.lp.mint(owner.address, ethers.utils.parseEther("1000"));

    const EighthRoot = await ethers.getContractFactory("EighthRoot");
    this.curve = await EighthRoot.deploy();

    this.chef = await deployChef(this.oath.address);
    await this.oath.mint(this.chef.address, ethers.utils.parseEther("100000000"));
    //const Rewarder = await ethers.getContractFactory("RewarderMock");
    //this.rewarder = await Rewarder.deploy(1, this.oath.address, this.chef.address);
  })

  describe("PoolLength", function () {
    it("PoolLength should execute", async function () {
      await addPool(this.chef.address, 100, this.lp.address, zeroAddress, this.curve.address);
      expect(await getPoolCount(this.chef.address)).to.be.equal(1);
    })
  })

  describe("Set", function () {
    it("Should emit event LogSetPool", async function () {
      await addPool(this.chef.address, 100, this.lp.address, zeroAddress, this.curve.address);
      await expect(this.chef.set(0, 100, zeroAddress, this.curve.address, false, false)).to.emit(this.chef, "LogSetPool");
      await expect(this.chef.set(0, 100, this.oath.address, this.curve.address, true, false)).to.emit(this.chef, "LogSetPool").
        withArgs(0, 100, this.oath.address, this.curve.address);
    })

    it("Should revert if invalid pool", async function () {
      await expect(this.chef.set(0, 100, zeroAddress, this.curve.address, false, false)).to.be.reverted;
    })
  })

  describe("PendingRelic", function () {
    it("PendingRelic should equal ExpectedRelic", async function () {
      await addPool(this.chef.address, 1, this.lp.address, zeroAddress, this.curve.address);
      await this.lp.approve(this.chef.address, ethers.utils.parseEther("1000"));
      await this.chef.createPositionAndDeposit(alice.address, 0, ethers.utils.parseEther("1"));
      await network.provider.send("evm_increaseTime", [31557600]);
      await network.provider.send("evm_mine");
      await this.chef.updatePool(0);
      await network.provider.send("evm_mine");
      const firstOwnedToken = await this.chef.tokenOfOwnerByIndex(alice.address, 0);
      const pendingOath = await this.chef.pendingOath(0, firstOwnedToken);
      expect(pendingOath).to.equal(ethers.BigNumber.from("3155760200000000000")); //(31557600 + 2) * 100000000000
    })
  })

  describe("MassUpdatePools", function () {
    it("Should call updatePool", async function () {
      await addPool(this.chef.address, 1, this.lp.address, zeroAddress, this.curve.address);
      await network.provider.send("evm_mine");
      await expect(this.chef.massUpdatePools([0])).to.emit(this.chef, "LogUpdatePool");
    })

    it("Updating invalid pools should fail", async function () {
      await expect(this.chef.massUpdatePools([0, 1000, 10000])).to.be.reverted;
    })
  })

  describe("AddPool", function () {
    it("Should add pool with reward token multiplier", async function () {
      await expect(this.chef.addPool(10, this.lp.address, zeroAddress, this.curve.address))
        .to.emit(this.chef, "LogPoolAddition")
        .withArgs(0, 10, this.lp.address, zeroAddress, this.curve.address);
    })
  })

  describe("UpdatePool", function () {
    it("Should emit event LogUpdatePool", async function () {
      await addPool(this.chef.address, 1, this.lp.address, zeroAddress, this.curve.address);
      await network.provider.send("evm_mine");
      await expect(this.chef.updatePool(0))
        .to.emit(this.chef, "LogUpdatePool")
        .withArgs(
          0,
          (await this.chef.poolInfo(0)).lastRewardTime,
          await this.lp.balanceOf(this.chef.address),
          (await this.chef.poolInfo(0)).accOathPerShare
        )
    })
  })

  describe("Deposit", function () {
    it("Depositing 1", async function () {
      await addPool(this.chef.address, 10, this.lp.address, zeroAddress, this.curve.address);
      await this.lp.approve(this.chef.address, 10);
      await expect(this.chef.createPositionAndDeposit(alice.address, 0, 1))
        .to.emit(this.chef, "Deposit")
        .withArgs(owner.address, 0, 1, alice.address, 0);
    })

    it("Depositing into non-existent pool should fail", async function () {
        await expect(this.chef.createPositionAndDeposit(alice.address, 1001, 1)).to.be.reverted;
    })
  })

  describe("Withdraw", function () {
    it("Withdraw 1", async function () {
      await addPool(this.chef.address, 10, this.lp.address, zeroAddress, this.curve.address);
      await this.lp.approve(this.chef.address, 10);
      await this.chef.createPositionAndDeposit(alice.address, 0, 1);
      const firstOwnedToken = await this.chef.tokenOfOwnerByIndex(alice.address, 0);
      await expect(this.chef.connect(alice).withdraw(0, 1, firstOwnedToken))
        .to.emit(this.chef, "Withdraw")
        .withArgs(alice.address, 0, 1, alice.address, firstOwnedToken);
    })
  })

  describe("Harvest", function () {
    it("Should give back the correct amount of RELIC", async function () {
      await addPool(this.chef.address, 1, this.lp.address, zeroAddress, this.curve.address);
      await this.lp.approve(this.chef.address, ethers.utils.parseEther("1000"));
      await this.chef.createPositionAndDeposit(alice.address, 0, ethers.utils.parseEther("1"));
      await network.provider.send("evm_increaseTime", [31557600]);
      await network.provider.send("evm_mine");
      const firstOwnedToken = await this.chef.tokenOfOwnerByIndex(alice.address, 0);
      await this.chef.connect(alice).harvest(0, firstOwnedToken);
      const balance = await this.oath.balanceOf(alice.address);
      expect(balance).to.equal(ethers.BigNumber.from("3155760100000000000")); // (31557600 + 1) * 100000000000
    })
  })

  describe("EmergencyWithdraw", function () {
    it("Should emit event EmergencyWithdraw", async function () {
      await addPool(this.chef.address, 10, this.lp.address, zeroAddress, this.curve.address);
      await this.lp.approve(this.chef.address, 10);
      await this.chef.createPositionAndDeposit(alice.address, 0, 1);
    })
  })
})
