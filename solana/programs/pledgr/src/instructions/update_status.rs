use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct UpdateStatus<'info> {
    #[account(
        mut,
        seeds = [SUBSCRIPTION_SEED, subscription.subscriber.as_ref(), &subscription.subscription_id],
        bump = subscription.bump,
    )]
    pub subscription: Account<'info, Subscription>,

    #[account(
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
        constraint = authority.key() == config.authority @ PledgrError::Unauthorized
    )]
    pub config: Account<'info, PledgrConfig>,

    pub authority: Signer<'info>,
}

pub fn handler(ctx: Context<UpdateStatus>, new_status: SubscriptionStatus) -> Result<()> {
    let subscription = &mut ctx.accounts.subscription;
    let old_status = subscription.status;

    require!(
        is_valid_status_transition(old_status, new_status),
        PledgrError::InvalidStatusTransition
    );

    subscription.status = new_status;

    emit!(StatusUpdated {
        subscription_id: subscription.subscription_id,
        old_status,
        new_status,
        timestamp: Clock::get()?.unix_timestamp,
    });

    Ok(())
}

#[event]
pub struct StatusUpdated {
    pub subscription_id: [u8; 32],
    pub old_status: SubscriptionStatus,
    pub new_status: SubscriptionStatus,
    pub timestamp: i64,
}
