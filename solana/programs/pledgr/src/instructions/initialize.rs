use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = authority,
        space = PledgrConfig::LEN,
        seeds = [PROCESSOR_SEED],
        bump
    )]
    pub config: Account<'info, PledgrConfig>,

    #[account(mut)]
    pub authority: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handler(
    ctx: Context<Initialize>,
    co_owner_one: Pubkey,
    co_owner_two: Pubkey,
    co_owner_three: Pubkey,
    usdt_mint: Pubkey,
    usdc_mint: Pubkey,
) -> Result<()> {
    require!(
        co_owner_one != Pubkey::default(),
        PledgrError::InvalidAmount
    );
    require!(
        co_owner_two != Pubkey::default(),
        PledgrError::InvalidAmount
    );
    require!(
        co_owner_three != Pubkey::default(),
        PledgrError::InvalidAmount
    );

    let config = &mut ctx.accounts.config;

    config.authority = ctx.accounts.authority.key();
    config.co_owner_one = co_owner_one;
    config.co_owner_two = co_owner_two;
    config.co_owner_three = co_owner_three;
    config.co_owner_one_bps = DEFAULT_CO_OWNER_ONE_BPS;
    config.co_owner_two_bps = DEFAULT_CO_OWNER_TWO_BPS;
    config.co_owner_three_bps = DEFAULT_CO_OWNER_THREE_BPS;
    config.supported_tokens = vec![usdt_mint, usdc_mint];
    config.total_processed = 0;
    config.total_subscriptions = 0;
    config.paused = false;
    config.bounty_per_renewal = DEFAULT_BOUNTY_PER_RENEWAL;
    config.max_bounty_per_tx = MAX_BOUNTY_PER_TX;
    config.bounty_enabled = true;
    config.bump = ctx.bumps.config;

    Ok(())
}
