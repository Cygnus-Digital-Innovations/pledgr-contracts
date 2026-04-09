use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_spl::token::Mint;

#[derive(Accounts)]
pub struct AddSupportedToken<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = config.authority == authority.key() @ PledgrError::Unauthorized
    )]
    pub config: Account<'info, PledgrConfig>,

    pub token_mint: Account<'info, Mint>,

    pub authority: Signer<'info>,
}

pub fn handler(ctx: Context<AddSupportedToken>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    let token_mint = ctx.accounts.token_mint.key();

    require!(
        !config.supported_tokens.contains(&token_mint),
        PledgrError::InvalidToken
    );
    require!(
        config.supported_tokens.len() < MAX_SUPPORTED_TOKENS,
        PledgrError::InvalidToken
    );

    config.supported_tokens.push(token_mint);
    Ok(())
}
