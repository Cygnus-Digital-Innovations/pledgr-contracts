use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct UpdateCoOwnerOne<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = current_wallet.key() == config.co_owner_one @ PledgrError::Unauthorized
    )]
    pub config: Account<'info, PledgrConfig>,
    pub current_wallet: Signer<'info>,
}

pub fn handler(ctx: Context<UpdateCoOwnerOne>, new_wallet: Pubkey) -> Result<()> {
    require!(new_wallet != Pubkey::default(), PledgrError::InvalidAmount);
    ctx.accounts.config.co_owner_one = new_wallet;
    Ok(())
}

#[derive(Accounts)]
pub struct UpdateCoOwnerTwo<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = current_wallet.key() == config.co_owner_two @ PledgrError::Unauthorized
    )]
    pub config: Account<'info, PledgrConfig>,
    pub current_wallet: Signer<'info>,
}

pub fn update_co_owner_two_handler(
    ctx: Context<UpdateCoOwnerTwo>,
    new_wallet: Pubkey,
) -> Result<()> {
    require!(new_wallet != Pubkey::default(), PledgrError::InvalidAmount);
    ctx.accounts.config.co_owner_two = new_wallet;
    Ok(())
}

#[derive(Accounts)]
pub struct UpdateCoOwnerThree<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = current_wallet.key() == config.co_owner_three @ PledgrError::Unauthorized
    )]
    pub config: Account<'info, PledgrConfig>,
    pub current_wallet: Signer<'info>,
}

pub fn update_co_owner_three_handler(
    ctx: Context<UpdateCoOwnerThree>,
    new_wallet: Pubkey,
) -> Result<()> {
    require!(new_wallet != Pubkey::default(), PledgrError::InvalidAmount);
    ctx.accounts.config.co_owner_three = new_wallet;
    Ok(())
}
