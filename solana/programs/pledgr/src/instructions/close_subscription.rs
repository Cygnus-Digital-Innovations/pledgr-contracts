use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct CloseSubscription<'info> {
    #[account(
        mut,
        seeds = [SUBSCRIPTION_SEED, subscription.subscriber.as_ref(), &subscription.subscription_id],
        bump = subscription.bump,
        close = rent_destination,
    )]
    pub subscription: Account<'info, Subscription>,

    #[account(
        seeds = [PROCESSOR_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, PledgrConfig>,

    // Intentionally permissionless: any signer can close an eligible subscription.
    // Rent is always refunded to the original subscriber (rent_destination constraint),
    // so the closer gains nothing. This allows permissionless cleanup of expired accounts.
    pub closer: Signer<'info>,

    /// CHECK: Rent refund always goes back to the original subscriber
    #[account(
        mut,
        constraint = rent_destination.key() == subscription.subscriber @ PledgrError::Unauthorized
    )]
    pub rent_destination: UncheckedAccount<'info>,
}

pub fn handler(ctx: Context<CloseSubscription>) -> Result<()> {
    let subscription = &ctx.accounts.subscription;
    let clock = Clock::get()?;

    match subscription.status {
        SubscriptionStatus::Cancelled => {}
        _ => {
            let grace_end = subscription
                .next_due
                .saturating_add(subscription.grace_secs as i64);
            require!(
                clock.unix_timestamp > grace_end,
                PledgrError::SubscriptionStillActive
            );
        }
    }

    emit!(SubscriptionClosed {
        subscription_id: subscription.subscription_id,
        subscriber: subscription.subscriber,
        creator: subscription.creator,
        status_at_close: subscription.status,
        closer: ctx.accounts.closer.key(),
        timestamp: clock.unix_timestamp,
    });

    Ok(())
}

#[event]
pub struct SubscriptionClosed {
    pub subscription_id: [u8; 32],
    pub subscriber: Pubkey,
    pub creator: Pubkey,
    pub status_at_close: SubscriptionStatus,
    pub closer: Pubkey,
    pub timestamp: i64,
}
