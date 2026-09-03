import { Button } from "@/app/components/reui/button"
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyTitle,
} from "@/app/components/reui/empty"
import { ArrowUpRightIcon } from "lucide-react"

export function Pattern() {
  return (
    <div className="flex items-center justify-center">
      <Empty>
        <EmptyHeader>
          <EmptyTitle>No projects yet</EmptyTitle>
          <EmptyDescription>
            You haven&apos;t created any projects yet. Get started by creating
            your first project.
          </EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <div className="flex gap-2">
            <Button asChild>
              <a href="#">Create project</a>
            </Button>
            <Button variant="outline">Import project</Button>
          </div>
          <Button variant="link" asChild className="text-muted-foreground">
            <a href="#">
              Learn more{" "}
              <ArrowUpRightIcon
              />
            </a>
          </Button>
        </EmptyContent>
      </Empty>
    </div>
  )
}