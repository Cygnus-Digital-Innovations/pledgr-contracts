use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct RemoveSupportedToken<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = config.authority == authority.key() @ PledgrError::Unauthorized
    )]
    pub config: Account<'info, PledgrConfig>,

    pub authority: Signer<'info>,
}

pub fn handler(ctx: Context<RemoveSupportedToken>, token_mint: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let pos = config
        .supported_tokens
        .iter()
        .position(|t| t == &token_mint);
    require!(pos.is_some(), PledgrError::TokenNotFound);

    let removed_token = config.supported_tokens[pos.unwrap()];
    config.supported_tokens.swap_remove(pos.unwrap());

    emit!(TokenRemoved {
        token_mint: removed_token,
        removed_at: Clock::get()?.unix_timestamp,
    });

    Ok(())
}

#[event]
pub struct TokenRemoved {
    pub token_mint: Pubkey,
    pub removed_at: i64,
}
