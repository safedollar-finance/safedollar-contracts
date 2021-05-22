import {expect} from './chai-setup';
// @ts-ignore
import {ethers} from 'hardhat';
import {Contract, ContractFactory, BigNumber, utils} from 'ethers';
import {SignerWithAddress} from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import {solidity} from 'ethereum-waffle';

import {
    ADDRESS_ZERO, fromWei,
    getLatestBlock,
    getLatestBlockNumber,
    MAX_UINT256,
    mineBlocks, mineBlockTimeStamp,
    toWei
} from './shared/utilities';

describe('BDOv2.test', () => {
    const {provider} = ethers;

    let operator: SignerWithAddress;
    let jackpotFund: SignerWithAddress;
    let bob: SignerWithAddress;
    let carol: SignerWithAddress;
    let david: SignerWithAddress;

    before('provider & accounts setting', async () => {
        [operator, jackpotFund, bob, carol, david] = await ethers.getSigners();
    });

    // core
    let Dollar: ContractFactory;
    let BDOv2: ContractFactory;
    let MockOracle: ContractFactory;
    let MockLiquidityFund: ContractFactory;

    before('fetch contract factories', async () => {
        Dollar = await ethers.getContractFactory('Dollar');
        BDOv2 = await ethers.getContractFactory('BDOv2');
        MockOracle = await ethers.getContractFactory('MockOracle');
        MockLiquidityFund = await ethers.getContractFactory('MockLiquidityFund');
    });

    let legacy: Contract;
    let bdov2: Contract;
    let oracle: Contract;
    let liquidityFund: Contract;

    before('deploy contracts', async () => {
        legacy = await Dollar.connect(operator).deploy();
        bdov2 = await BDOv2.connect(operator).deploy();
        oracle = await MockOracle.connect(operator).deploy();
        liquidityFund = await MockLiquidityFund.connect(operator).deploy();
        await bdov2.connect(operator).initialize(legacy.address, toWei('1000000'), [liquidityFund.address]);
        await bdov2.connect(operator).setDollarOracle(oracle.address);
        await bdov2.connect(operator).setLiquidityFund(liquidityFund.address);
        await bdov2.connect(operator).setMinter(operator.address, true);
        await legacy.connect(operator).mint(bob.address, toWei('1000'));
        await legacy.connect(bob).approve(bdov2.address, MAX_UINT256);
    });

    describe('#constructor', () => {
        it('should works correctly', async () => {
            expect(String(await bdov2.name())).to.eq('bDollar 2.0');
            expect(String(await bdov2.symbol())).to.eq('BDOv2');
            expect(String(await bdov2.cap())).to.eq(toWei('1000000'));
            expect(String(await bdov2.totalSupply())).to.eq(toWei('0'));
            expect(String(await bdov2.burnRate())).to.eq('200');
            expect(String(await bdov2.addLiquidityRate())).to.eq('10');
            expect(String(await bdov2.minAmountToAddLiquidity())).to.eq(toWei('1000'));
            expect(String(await bdov2.addLiquidityAccumulated())).to.eq(toWei('0'));
            expect(String(await bdov2.dollarOracle())).to.eq(oracle.address);
            expect(String(await bdov2.liquidityFund())).to.eq(liquidityFund.address);
        });

        it('should fail if initialize twice', async () => {
            await expect(bdov2.connect(operator).initialize(legacy.address, toWei('1000000'), [liquidityFund.address])).to.revertedWith('Contract instance has already been initialized');
        });
    });

    describe('#setMinter', () => {
        it('add minter for carol', async () => {
            await bdov2.connect(operator).setMinter(carol.address, true);
            expect(await bdov2.minter(carol.address)).to.be.true;
        });

        it('carol mint 10 BDOv2 for david', async () => {
            await expect(async () => {
                await bdov2.connect(carol).mint(carol.address, toWei('10'));
                await bdov2.connect(carol).mint(david.address, toWei('20'));
            }).to.changeTokenBalances(bdov2, [carol, david], [toWei('10'), toWei('20')]);
            expect(String(await bdov2.totalSupply())).to.eq(toWei('30'));
        });

        it('should fail if carol mint more than cap', async () => {
            await expect(bdov2.connect(carol).mint(carol.address, toWei('999999'))).to.revertedWith('cap exceeded');
        });

        it('remove minter of carol', async () => {
            await bdov2.connect(operator).setMinter(carol.address, false);
            expect(await bdov2.minter(carol.address)).to.be.false;
        });

        it('should fail if carol mint more', async () => {
            await expect(bdov2.connect(carol).mint(carol.address, toWei('10'))).to.revertedWith('!minter');
        });

        it('should fail if add minter for carol by non-privilege account', async () => {
            await expect(bdov2.connect(bob).mint(carol.address, toWei('10'))).to.revertedWith('!minter');
        });
    });

    describe('#migrate', () => {
        it('should fail if migrationEnabled=false', async () => {
            await bdov2.setMigrationEnabled(false);
            await expect(bdov2.connect(bob).migrate(toWei('10'))).to.revertedWith('migration is not enabled');
            await bdov2.setMigrationEnabled(true);
        });

        it('bob migrate 10 legacy BDO', async () => {
            await expect(async () => {
                await bdov2.connect(bob).migrate(toWei('10'));
            }).to.changeTokenBalances(legacy, [bob, bdov2], [toWei('-10'), toWei('0')]);
            expect(String(await bdov2.balanceOf(bob.address))).to.eq(toWei('10'));
        });

        it('should fail if migrate more than balance', async () => {
            await expect(bdov2.connect(bob).migrate(toWei('990.1'))).to.revertedWith('transfer amount exceeds balance');
        });
    });

    describe('#transfer', () => {
        it('transfer when over-peg: only liquidity fee', async () => {
            await bdov2.connect(operator).mint(bob.address, toWei('100000'));
            await oracle.setPrice(toWei('1.01'));
            await expect(async () => {
                await bdov2.connect(bob).transfer(carol.address, toWei('10000'));
            }).to.changeTokenBalances(bdov2, [bob, carol, liquidityFund], [toWei('-10000'), toWei('9990'), toWei('0')]);
            expect(String(await bdov2.totalBurned())).to.eq(toWei('10'));
            expect(String(await bdov2.totalSupply())).to.eq(toWei('100030'));
            expect(String(await bdov2.addLiquidityAccumulated())).to.eq(toWei('10'));
        });

        it('transfer when under-peg: burning fee max when price is low ($0.3)', async () => {
            await oracle.setPrice(toWei('0.3'));
            await expect(async () => {
                await bdov2.connect(bob).transfer(carol.address, toWei('10000'));
            }).to.changeTokenBalances(bdov2, [bob, carol, liquidityFund], [toWei('-10000'), toWei('9790'), toWei('0')]);
            expect(String(await bdov2.totalBurned())).to.eq(toWei('220'));
            expect(String(await bdov2.totalSupply())).to.eq(toWei('99820'));
            expect(String(await bdov2.addLiquidityAccumulated())).to.eq(toWei('20'));
        });

        it('transfer when under-peg: burning fee half when price is ($0.5+$0.998) * 0.5', async () => {
            await oracle.setPrice(toWei('0.749'));
            await expect(async () => {
                await bdov2.connect(bob).transfer(carol.address, toWei('10000'));
            }).to.changeTokenBalances(bdov2, [bob, carol, liquidityFund], [toWei('-10000'), toWei('9890'), toWei('0')]);
            expect(String(await bdov2.totalBurned())).to.eq(toWei('330'));
            expect(String(await bdov2.totalSupply())).to.eq(toWei('99710'));
            expect(String(await bdov2.addLiquidityAccumulated())).to.eq(toWei('30'));
        });

        it('addLiquidityAccumulated enough to call addLiquidity', async () => {
            await oracle.setPrice(toWei('0.998')); // exact peg (no burning fee)
            await bdov2.connect(operator).setMinAmountToAddLiquidity(toWei('40'));
            await expect(async () => {
                await bdov2.connect(bob).transfer(carol.address, toWei('10000'));
            }).to.changeTokenBalances(bdov2, [bob, carol, liquidityFund], [toWei('-10000'), toWei('9990'), toWei('40')]);
            expect(String(await bdov2.totalBurned())).to.eq(toWei('340'));
            expect(String(await bdov2.totalSupply())).to.eq(toWei('99740'));
            expect(String(await bdov2.addLiquidityAccumulated())).to.eq(toWei('0'));
        });
    });

    describe('#transfer from excluded account', () => {
        it('transfer from usual to usual account', async () => {
            await oracle.setPrice(toWei('0.3'));
            await expect(async () => {
                await bdov2.connect(bob).transfer(carol.address, toWei('10000'));
            }).to.changeTokenBalances(bdov2, [bob, carol, liquidityFund], [toWei('-10000'), toWei('9790'), toWei('0')]);
            expect(String(await bdov2.totalBurned())).to.eq(toWei('550'));
            expect(String(await bdov2.totalSupply())).to.eq(toWei('99530'));
            expect(String(await bdov2.addLiquidityAccumulated())).to.eq(toWei('10'));
        });

        it('transfer from excluded to usual account', async () => {
            await bdov2.connect(operator).setExcludeFromFee(bob.address, true);
            await oracle.setPrice(toWei('0.3'));
            await expect(async () => {
                await bdov2.connect(bob).transfer(carol.address, toWei('10000'));
            }).to.changeTokenBalances(bdov2, [bob, carol, liquidityFund], [toWei('-10000'), toWei('10000'), toWei('0')]);
            expect(String(await bdov2.totalBurned())).to.eq(toWei('550'));
            expect(String(await bdov2.totalSupply())).to.eq(toWei('99530'));
            expect(String(await bdov2.addLiquidityAccumulated())).to.eq(toWei('10'));
        });

        it('transfer from usual to excluded account', async () => {
            await bdov2.connect(operator).setExcludeFromFee(bob.address, false);
            await bdov2.connect(operator).setExcludeToFee(carol.address, true);
            await oracle.setPrice(toWei('0.3'));
            await expect(async () => {
                await bdov2.connect(bob).transfer(carol.address, toWei('10000'));
            }).to.changeTokenBalances(bdov2, [bob, carol, liquidityFund], [toWei('-10000'), toWei('10000'), toWei('0')]);
            expect(String(await bdov2.totalBurned())).to.eq(toWei('550'));
            expect(String(await bdov2.totalSupply())).to.eq(toWei('99530'));
            expect(String(await bdov2.addLiquidityAccumulated())).to.eq(toWei('10'));
        });
    });

    describe('#transfer with jackpot fee', () => {
        it('should work with 10% jackpot fee', async () => {
            await bdov2.connect(operator).setExcludeFromFee(bob.address, false);
            await bdov2.connect(operator).setExcludeToFee(carol.address, false);
            await bdov2.connect(operator).setJackpotRate(1000); // 10%
            await bdov2.connect(operator).setJackpotFund(jackpotFund.address);
            await oracle.setPrice(toWei('0.3'));
            await expect(async () => {
                await bdov2.connect(bob).transfer(carol.address, toWei('10000'));
            }).to.changeTokenBalances(bdov2, [bob, carol, liquidityFund, jackpotFund], [toWei('-10000'), toWei('8790'), toWei('0'), toWei('1000')]);
            expect(String(await bdov2.totalBurned())).to.eq(toWei('760'));
            expect(String(await bdov2.totalSupply())).to.eq(toWei('99320'));
            expect(String(await bdov2.addLiquidityAccumulated())).to.eq(toWei('20'));
        });
    });
});
