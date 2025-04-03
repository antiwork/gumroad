import * as React from "react";

import { followWishlist, unfollowWishlist } from "$app/data/wishlists";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { WithTooltip } from "$app/components/WithTooltip";

export const useFollowWishlist = ({
  wishlistId,
  wishlistName,
  initialValue,
}: {
  wishlistId: string;
  wishlistName: string;
  initialValue: boolean;
}) => {
  const location = useOriginalLocation();
  const loggedInUser = useLoggedInUser();
  const { appDomain } = useDomains();

  const [isFollowing, setIsFollowing] = React.useState(initialValue);
  const [isLoading, setIsLoading] = React.useState(false);

  const toggleFollowing = async () => {
    if (!isFollowing && !loggedInUser) {
      window.location.href = Routes.login_url({ host: appDomain, next: location });
      return;
    }

    setIsLoading(true);
    try {
      const action = isFollowing ? unfollowWishlist : followWishlist;
      await action({ wishlistId });
      setIsFollowing(!isFollowing);
      showAlert(
        isFollowing ? `You are no longer following ${wishlistName}.` : `You are now following ${wishlistName}!`,
        "success",
      );
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  return {
    isFollowing,
    isLoading,
    toggleFollowing,
  };
};

export const FollowButton = ({
  wishlistId,
  wishlistName,
  initialValue,
}: {
  wishlistId: string;
  wishlistName: string;
  initialValue: boolean;
}) => {
  const { isFollowing, isLoading, toggleFollowing } = useFollowWishlist({
    wishlistId,
    wishlistName,
    initialValue,
  });

  return isFollowing ? (
    <WithTooltip tip="Unfollow">
      <Button onClick={() => void toggleFollowing()} color="primary" disabled={isLoading}>
        <Icon name="bookmark-check-fill" />
        Following
      </Button>
    </WithTooltip>
  ) : (
    <Button onClick={() => void toggleFollowing()} disabled={isLoading}>
      <Icon name="bookmark-plus" />
      Follow wishlist
    </Button>
  );
};
