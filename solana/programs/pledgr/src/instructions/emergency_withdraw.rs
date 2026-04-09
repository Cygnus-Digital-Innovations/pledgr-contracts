use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

#[derive(Accounts)]
pub struct EmergencyWithdraw<'info> {
    #[account(
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = config.authority == authority.key() @ PledgrError::Unauthorized,
        constraint = config.paused @ PledgrError::ProgramNotPaused
    )]
    pub config: Account<'info, PledgrConfig>,

    #[account(
        mut,
        constraint = source_token_account.owner == config.key() @ PledgrError::Unauthorized
    )]
    pub source_token_account: Account<'info, TokenAccount>,

    #[account(
        mut,
        constraint = destination_token_account.owner == authority.key() @ PledgrError::Unauthorized,
        constraint = destination_token_account.mint == source_token_account.mint @ PledgrError::InvalidToken
    )]
    pub destination_token_account: Account<'info, TokenAccount>,

    pub authority: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

pub fn handler(ctx: Context<EmergencyWithdraw>) -> Result<()> {
    let amount = ctx.accounts.source_token_account.amount;
    require!(amount > 0, PledgrError::InvalidAmount);

    let seeds = &[PROCESSOR_SEED, &[ctx.accounts.config.bump]];
    let signer_seeds = &[&seeds[..]];

    token::transfer(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.source_token_account.to_account_info(),
                to: ctx.accounts.destination_token_account.to_account_info(),
                authority: ctx.accounts.config.to_account_info(),
            },
            signer_seeds,
        ),
        amount,
    )?;

    Ok(())
}
