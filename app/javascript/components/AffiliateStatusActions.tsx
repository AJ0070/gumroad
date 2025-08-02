import * as React from "react";
import { request } from "$app/utils/request";
import { showAlert } from "$app/components/server-components/Alert";
import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { WithTooltip } from "$app/components/WithTooltip";
import "./AffiliateStatusActions.css";

type Status = "pending" | "approved" | "denied" | "revoked";

interface AffiliateStatusActionsProps {
  affiliateLinkId: number;
  currentStatus: Status;
  onStatusChange: (newStatus: Status) => void;
  className?: string;
}

export const AffiliateStatusActions: React.FC<AffiliateStatusActionsProps> = ({
  affiliateLinkId,
  currentStatus,
  onStatusChange,
  className = "",
}) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const updateStatus = async (action: "approve" | "deny" | "revoke") => {
    if (isLoading) return;

    setIsLoading(true);
    try {
      const response = await request({
        method: "PATCH",
        url: `/affiliate_links/${affiliateLinkId}/${action}`,
        accept: "json",
      });

      const data = await response.json();
      if (data.success) {
        onStatusChange(data.status);
        showAlert({
          message: `Affiliate status updated to ${data.status}`,
          type: "success",
        });
      } else {
        throw new Error(data.error || "Failed to update status");
      }
    } catch (error) {
      console.error("Error updating affiliate status:", error);
      showAlert({
        message: error.message || "Failed to update status. Please try again.",
        type: "error",
      });
    } finally {
      setIsLoading(false);
    }
  };

  // If status is pending, show approve/deny buttons
  if (currentStatus === "pending") {
    return (
      <div className={`flex space-x-2 ${className}`}>
        <WithTooltip content="Approve affiliate">
          <Button
            size="sm"
            variant="success"
            onClick={() => updateStatus("approve")}
            disabled={isLoading}
            className="p-1"
          >
            <Icon name="check" className="h-4 w-4" />
          </Button>
        </WithTooltip>
        <WithTooltip content="Deny affiliate">
          <Button size="sm" variant="danger" onClick={() => updateStatus("deny")} disabled={isLoading} className="p-1">
            <Icon name="x" className="h-4 w-4" />
          </Button>
        </WithTooltip>
      </div>
    );
  }

  // If status is approved, show revoke button
  if (currentStatus === "approved") {
    return (
      <div className={className}>
        <WithTooltip content="Revoke affiliate access">
          <Button
            size="sm"
            variant="ghost"
            onClick={() => updateStatus("revoke")}
            disabled={isLoading}
            className="text-gray-500 hover:text-red-500 p-1"
          >
            <Icon name="trash-2" className="h-4 w-4" />
          </Button>
        </WithTooltip>
      </div>
    );
  }

  // If status is denied or revoked, show reset button
  return (
    <div className={className}>
      <WithTooltip content="Reset status to pending">
        <Button
          size="sm"
          variant="outline"
          onClick={() => updateStatus("approve")}
          disabled={isLoading}
          className="text-xs"
        >
          Reset
        </Button>
      </WithTooltip>
    </div>
  );
};
