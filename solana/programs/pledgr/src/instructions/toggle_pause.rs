use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct TogglePause<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = config.authority == authority.key() @ PledgrError::Unauthorized
    )]
    pub config: Account<'info, PledgrConfig>,

    pub authority: Signer<'info>,
}

pub fn handler(ctx: Context<TogglePause>, paused: bool) -> Result<()> {
    ctx.accounts.config.paused = paused;
    Ok(())
}
