import { Button } from "@/app/components/reui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/app/components/reui/card"
import { Input } from "@/app/components/reui/input"
import { Label } from "@/app/components/reui/label"
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "@/app/components/reui/tabs"

export function Pattern() {
  return (
    <div className="flex w-full max-w-xs flex-col gap-6">
      <Tabs defaultValue="account">
        <TabsList>
          <TabsTrigger value="account">Account</TabsTrigger>
          <TabsTrigger value="password">Password</TabsTrigger>
        </TabsList>
        <TabsContent value="account">
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base">Account</CardTitle>
              <CardDescription className="text-sm">
                Update your account information.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="name" className="text-sm">
                  Name
                </Label>
                <Input id="name" defaultValue="Sarah Johnson" className="h-9" />
              </div>
              <div className="space-y-2">
                <Label htmlFor="username" className="text-sm">
                  Username
                </Label>
                <Input id="username" defaultValue="@sarahj" className="h-9" />
              </div>
            </CardContent>
            <CardFooter className="pt-3">
              <Button size="sm">Save changes</Button>
            </CardFooter>
          </Card>
        </TabsContent>
        <TabsContent value="password">
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="text-base">Password</CardTitle>
              <CardDescription className="text-sm">
                Change your password here.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="current" className="text-sm">
                  Current password
                </Label>
                <Input id="current" type="password" className="h-9" />
              </div>
              <div className="space-y-2">
                <Label htmlFor="new" className="text-sm">
                  New password
                </Label>
                <Input id="new" type="password" className="h-9" />
              </div>
            </CardContent>
            <CardFooter className="pt-3">
              <Button size="sm">Update password</Button>
            </CardFooter>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  )
}