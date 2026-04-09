use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct SetBountyConfig<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = config.authority == authority.key() @ PledgrError::Unauthorized
    )]
    pub config: Account<'info, PledgrConfig>,
    pub authority: Signer<'info>,
}

pub fn set_bounty_config_handler(
    ctx: Context<SetBountyConfig>,
    bounty_per_renewal: u64,
    max_bounty_per_tx: u64,
    enabled: bool,
) -> Result<()> {
    require!(bounty_per_renewal <= 1_000_000, PledgrError::InvalidAmount);
    require!(max_bounty_per_tx <= 100_000_000, PledgrError::InvalidAmount);

    let config = &mut ctx.accounts.config;
    config.bounty_per_renewal = bounty_per_renewal;
    config.max_bounty_per_tx = max_bounty_per_tx;
    config.bounty_enabled = enabled;
    Ok(())
}
