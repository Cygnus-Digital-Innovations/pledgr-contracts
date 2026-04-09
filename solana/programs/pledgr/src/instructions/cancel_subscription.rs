use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct CancelSubscription<'info> {
    #[account(
        mut,
        seeds = [SUBSCRIPTION_SEED, subscription.subscriber.as_ref(), &subscription.subscription_id],
        bump = subscription.bump,
        constraint = authority.key() == subscription.subscriber ||
                     authority.key() == subscription.creator ||
                     authority.key() == config.authority @ PledgrError::Unauthorized,
        constraint = subscription.status != SubscriptionStatus::Cancelled @ PledgrError::SubscriptionNotActive
    )]
    pub subscription: Account<'info, Subscription>,

    #[account(
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, PledgrConfig>,

    pub authority: Signer<'info>,
}

pub fn handler(ctx: Context<CancelSubscription>) -> Result<()> {
    let subscription = &mut ctx.accounts.subscription;
    let old_status = subscription.status;
    subscription.status = SubscriptionStatus::Cancelled;
    subscription.auto_renewal_consent.enabled = false;
    subscription.auto_renewal_consent.max_allowance = 0;

    emit!(SubscriptionCancelled {
        subscription_id: subscription.subscription_id,
        old_status,
        timestamp: Clock::get()?.unix_timestamp,
    });

    Ok(())
}

#[event]
pub struct SubscriptionCancelled {
    pub subscription_id: [u8; 32],
    pub old_status: SubscriptionStatus,
    pub timestamp: i64,
}
