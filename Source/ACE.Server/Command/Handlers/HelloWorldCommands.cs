using ACE.Entity.Enum;
using ACE.Server.Network;

namespace ACE.Server.Command.Handlers
{
    public static class HelloWorldCommands
    {
        // helloworld
        [CommandHandler("helloworld", AccessLevel.Player, CommandHandlerFlag.RequiresWorld, 0,
            "Sends a hello-world system message to you.",
            "")]
        public static void HandleHelloWorld(Session session, params string[] parameters)
        {
            CommandHandlerHelper.WriteOutputInfo(session, "Hello, world from ACE (ogmage78 fork).", ChatMessageType.System);
        }
    }
}
