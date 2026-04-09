use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct SetCoOwner<'info> {
    #[account(
        mut,
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = config.authority == authority.key() @ PledgrError::Unauthorized
    )]
    pub config: Account<'info, PledgrConfig>,

    pub authority: Signer<'info>,
}

pub fn handler(
    ctx: Context<SetCoOwner>,
    new_co_owner_one: Pubkey,
    new_co_owner_two: Pubkey,
    new_co_owner_three: Pubkey,
) -> Result<()> {
    let config = &mut ctx.accounts.config;

    require!(
        new_co_owner_one != Pubkey::default(),
        PledgrError::InvalidAmount
    );
    require!(
        new_co_owner_two != Pubkey::default(),
        PledgrError::InvalidAmount
    );
    require!(
        new_co_owner_three != Pubkey::default(),
        PledgrError::InvalidAmount
    );

    config.co_owner_one = new_co_owner_one;
    config.co_owner_two = new_co_owner_two;
    config.co_owner_three = new_co_owner_three;
    Ok(())
}
